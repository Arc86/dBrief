import Foundation

extension ProcessingPipeline {
    /// Frozen once before intent. The same small inventory survives partial
    /// removal, including loss of the metadata which supplied privacy ownership.
    struct FileDeletionTicket: Sendable {
        let authority: RecordingDeletionAuthority
        let items: [RecordingDeletionAuthority.Item]
        let recoveryDirectory: RecordingDeletionAuthority.Item?
        let discard: DiscardRequest?
        let bytes: Int
        var snapshots = RecoveryLifecycle.DeletionSnapshot()
        var privacyTargets: [URL] = []
        var recordingID: UUID? { authority.recordingID }
        func adoptingVerifiedRecordingID(_ id: UUID) throws -> Self {
            try validateFiles()
            var value = Self(authority: try authority.adoptingVerifiedRecordingID(id), items: items,
                recoveryDirectory: recoveryDirectory, discard: discard, bytes: bytes)
            value.snapshots = snapshots; value.privacyTargets = privacyTargets
            return value
        }

        static func freeze(audioURL: URL, recordingID: UUID? = nil, discard: DiscardRequest? = nil,
                           manifestID: UUID? = nil, originalAuthority: RecordingDeletionAuthority? = nil) throws -> Self {
            try RecordingResultMutation.withDeletion(of: audioURL) {
                let authority = try originalAuthority ?? RecordingDeletionAuthority(audioURL: audioURL, expectedRecordingID: recordingID)
                try authority.validate()
                var items: [RecordingDeletionAuthority.Item] = [], seen = Set<URL>(), bytes = 512 + (try RecordingDeletionAuthority.charge(audioURL))
                func append(_ url: URL, directory: Bool = false) throws -> RecordingDeletionAuthority.Item {
                    let item = try RecordingDeletionAuthority.Item(url, directory: directory)
                    if seen.insert(item.url).inserted {
                        let cost = try RecordingDeletionAuthority.charge(item.url)
                        guard items.count < 128, cost <= RecordingDeletionAuthority.ticketLimit - bytes else { throw LiveArtifactError.artifactTooLarge }
                        bytes += cost; items.append(item)
                    }
                    return item
                }
                _ = try append(authority.audioURL); _ = try append(authority.metadata.url)
                var recoveryDirectory: RecordingDeletionAuthority.Item?
                if let discard {
                    guard discard.knownFiles.count <= 128 else { throw LiveArtifactError.artifactTooLarge }
                    for url in discard.knownFiles { _ = try append(url) }
                    if let manifest = discard.recoveryManifestURL, try RecordingDeletionAuthority.Stamp.read(manifest) != nil {
                        _ = try append(manifest)
                        struct ManifestOwner: Decodable { let id: UUID }
                        guard let value: ManifestOwner = try RecordingDeletionAuthority.readHeader(manifest) else { throw LiveArtifactError.verificationFailed }
                        guard manifestID == nil || value.id == manifestID else { throw LiveArtifactError.wrongOwner }
                        let directory = try append(manifest.deletingLastPathComponent(), directory: true)
                        recoveryDirectory = directory
                        try scan(directory.url, recursive: true) { _ = try append($0, directory: isDirectory($0)) }
                    }
                } else {
                    let base = authority.audioURL.deletingPathExtension()
                    for suffix in ["md", "transcript.json", "richtranscript.json", "insights.json", "chat.json",
                                   "spokensummary.json", "spokensummary.m4a", "reprocessing.json", "json", "queue.json"] {
                        _ = try append(base.appendingPathExtension(suffix))
                    }
                    let prefix = base.lastPathComponent + "_part"
                    try scan(base.deletingLastPathComponent(), recursive: false) { url in
                        let stem = url.deletingPathExtension().lastPathComponent
                        guard RecordingDiscovery.supportedExtensions.contains(url.pathExtension.lowercased()), stem.hasPrefix(prefix),
                              !stem.dropFirst(prefix.count).isEmpty, stem.dropFirst(prefix.count).allSatisfy(\.isNumber) else { return }
                        _ = try append(url)
                    }
                }
                return Self(authority: authority, items: items, recoveryDirectory: recoveryDirectory, discard: discard, bytes: bytes)
            }
        }
        private static func isDirectory(_ url: URL) throws -> Bool {
            let value = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard value.isSymbolicLink != true else { throw LiveArtifactError.unsafePath }
            return value.isDirectory == true
        }
        private static func scan(_ directory: URL, recursive: Bool, visit: (URL) throws -> Void) throws {
            var failure: (any Error)?
            guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                options: recursive ? [] : [.skipsSubdirectoryDescendants], errorHandler: { _, error in failure = error; return false }) else { throw LiveArtifactError.unsafePath }
            var count = 0
            for case let url as URL in iterator {
                count += 1; guard count <= 4_096 else { throw LiveArtifactError.artifactTooLarge }
                try visit(url)
            }
            if let failure { throw failure }
        }
        func validateFiles() throws {
            try authority.validate()
            for item in items { try item.validate() }
            if let directory = recoveryDirectory, try RecordingDeletionAuthority.Stamp.read(directory.url, directory: true) != nil {
                // A new scratch child is never inherited by a deletion retry.
                let originals = Set(items.map(\.url))
                try Self.scan(directory.url, recursive: true) {
                    guard originals.contains($0) else { throw LiveArtifactError.wrongOwner }
                }
            }
        }
    }

    func prepareDeletion(_ frozen: FileDeletionTicket, lifecycle: RecoveryLifecycle?, store: PrivacyReceiptStore) async throws -> FileDeletionTicket {
        var value = frozen
        if let lifecycle { value.snapshots = try await lifecycle.deletionSnapshot(for: value.authority.audioURL,
            byteLimit: RecordingDeletionAuthority.ticketLimit - value.bytes) }
        var ids = value.snapshots.recordingIDs
        if let id = value.recordingID { ids.insert(id) }
        value.privacyTargets = try await store.boundedDeletionTargets(for: value.authority.audioURL, recordingIDs: ids,
            extra: value.discard?.pendingReceiptURL,
            byteLimit: RecordingDeletionAuthority.ticketLimit - value.bytes - value.snapshots.charge)
        return value
    }

    func removeDeletionFiles(_ ticket: FileDeletionTicket, lifecycle: RecoveryLifecycle?, store: PrivacyReceiptStore,
                             files: DeletionFiles = .init(), allowSharedAudio: Bool = false) async throws {
        try await files.beforeRemoval()
        if let lifecycle { try await lifecycle.removeSnapshots(for: ticket.authority.audioURL, expected: ticket.snapshots, authority: ticket.authority) }
        let fm = files.fileManager()
        var firstError: (any Error)?
        var removedSession: URL?
        try RecordingResultMutation.withDeletion(of: ticket.authority.audioURL) {
            try ticket.validateFiles()
            if let directory = ticket.recoveryDirectory, fm.fileExists(atPath: directory.url.path) {
                do { try fm.removeItem(at: directory.url); removedSession = directory.url }
                catch { firstError = error }
            }
            for item in ticket.items where !item.directory && fm.fileExists(atPath: item.url.path) {
                do { try fm.removeItem(at: item.url) } catch { firstError = firstError ?? error }
            }
        }
        let absent = ticket.items.allSatisfy { !fm.fileExists(atPath: $0.url.path) }
        if absent {
            if let directory = ticket.recoveryDirectory, directory.stamp != nil,
               !fm.fileExists(atPath: directory.url.path) { removedSession = directory.url }
            let safe: Bool
            if let discard = ticket.discard {
                safe = PrivacyReceiptLifecycle.canRemoveDiscardedEvidence(audioURL: ticket.authority.audioURL,
                    finalized: discard.finalized, knownFiles: ticket.items.filter { !$0.directory }.map(\.url),
                    removedSessionDirectory: removedSession, fileManager: fm)
            } else {
                safe = try !PrivacyReceiptLifecycle.hasSurvivingAudio(for: PrivacyReceiptLifecycle.receiptURL(for: ticket.authority.audioURL), fileManager: fm)
            }
            if safe { try await files.removeEvidence(store, ticket) }
            else if !allowSharedAudio { throw LiveArtifactError.verificationFailed }
        } else if firstError == nil { firstError = LiveArtifactError.verificationFailed }
        if let firstError { throw firstError }
        if let discard = ticket.discard {
            files.record(.init(sessionID: discard.recordingID, name: "recording_discarded_by_user", outcome: .succeeded))
        }
    }
}
