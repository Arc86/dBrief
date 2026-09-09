import Foundation
import Darwin
import CryptoKit

/// All production contexts share this actor, serializing read-modify-write
/// operations even when multiple recording tasks finish at the same time.
actor PrivacyReceiptStore {
    static let shared = PrivacyReceiptStore()
    static let maximumFileBytes = 16 * 1_024 * 1_024
    static let maximumStoredAttempts = 10_000

    enum StoreError: Error {
        case unsupportedVersion, invalidEvidence, unsafeFile, oversizedFile
        case unknownAttempt, conflictingCompletion, verificationFailed, deletedRecording
    }

    private let maximumAttempts: Int
    private let gapDirectoryURL: URL
    private var unpersistedGaps = Set<String>()
    private var aliases: [String: URL] = [:]
    private var suppressedKeys = Set<String>()
    private var pendingRoots: Set<URL>

    init(maximumAttempts: Int = maximumStoredAttempts,
         gapDirectoryURL: URL = AppSupportPaths.subdirectory("Privacy Receipt Gaps"),
         pendingDirectoryURL: URL = AppSupportPaths.subdirectory("Privacy Pending")) {
        self.maximumAttempts = min(max(0, maximumAttempts), Self.maximumStoredAttempts)
        self.gapDirectoryURL = gapDirectoryURL
        self.pendingRoots = [pendingDirectoryURL]
    }

    nonisolated static func sidecarURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("privacy.json")
    }

    func load(from url: URL) throws -> PrivacyReceipt? {
        let url = resolvedURL(url)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw StoreError.unsafeFile }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes else { throw StoreError.oversizedFile }
        struct Header: Decodable { let version: Int }
        let decoder = JSONDecoder()
        guard try decoder.decode(Header.self, from: data).version == PrivacyReceipt.currentVersion else {
            throw StoreError.unsupportedVersion
        }
        var receipt = try decoder.decode(PrivacyReceipt.self, from: data)
        guard receipt.attempts.count <= Self.maximumStoredAttempts, receipt.omittedAttempts >= 0,
              receipt.omittedAttempts == 0 || receipt.hasGaps,
              Set(receipt.attempts.map(\.id)).count == receipt.attempts.count,
              receipt.attempts.allSatisfy({
                  !$0.operation.data.isEmpty && $0.operation.destination.isValid
                      && (($0.outcome == .started) == ($0.finishedAt == nil))
              }) else { throw StoreError.invalidEvidence }
        if hasUnpersistedGap(at: url) { receipt.hasGaps = true }
        return receipt
    }

    /// Does not create scopes, migrate files, or write gap markers. Read all
    /// surviving locations so a failed finalization transfer remains visible.
    func snapshot(at urls: [URL]) -> PrivacyReceiptSnapshot {
        var snapshot = PrivacyReceiptSnapshot()
        var seen = Set<String>()
        var attempts: [UUID: PrivacyAttempt] = [:]
        var conflicts = Set<UUID>()
        var locations = urls
        for url in urls {
            locations += associatedPendingURLs(for: url)
            if pendingID(url) == nil, url.lastPathComponent.hasSuffix(".privacy.json") {
                let audio = url.deletingPathExtension().deletingPathExtension().appendingPathExtension("m4a")
                if let id = PrivacyReceiptLifecycle.recordingID(for: audio) {
                    locations += pendingRoots.map { $0.appendingPathComponent(id.uuidString + ".privacy.json") }
                }
            }
        }
        for original in locations {
            let url = resolvedURL(original)
            guard seen.insert(receiptKey(url)).inserted else { continue }
            snapshot.hasGaps = snapshot.hasGaps || hasUnpersistedGap(at: url)
            do {
                guard let receipt = try load(from: url) else { continue }
                snapshot.hasReceipt = true
                snapshot.hasGaps = snapshot.hasGaps || receipt.hasGaps
                snapshot.omittedAttempts = max(snapshot.omittedAttempts, receipt.omittedAttempts)
                for attempt in receipt.attempts {
                    if conflicts.contains(attempt.id) { continue }
                    if let existing = attempts[attempt.id] {
                        guard existing.operation == attempt.operation, existing.runID == attempt.runID,
                              existing.startedAt == attempt.startedAt,
                              existing.outcome == .started || attempt.outcome == .started
                                || existing == attempt else {
                            snapshot.hasGaps = true
                            conflicts.insert(attempt.id)
                            // Conflicting completions must never look confirmed.
                            var uncertain = existing
                            uncertain.outcome = .started
                            uncertain.finishedAt = nil
                            attempts[attempt.id] = uncertain
                            continue
                        }
                        if existing.outcome != .started { continue }
                    }
                    attempts[attempt.id] = attempt
                }
            } catch {
                snapshot.hasUnreadableReceipt = true
                snapshot.hasGaps = true
            }
        }
        snapshot.attempts = attempts.values.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
        }
        return snapshot
    }

    @discardableResult
    func begin(_ operation: PrivacyOperation, runID: UUID, at url: URL) throws -> UUID? {
        guard !isSuppressed(url) else { return nil }
        let url = resolvedURL(url)
        guard !isSuppressed(url) else { return nil }
        guard operation.destination.isValid, !operation.data.isEmpty else { throw StoreError.invalidEvidence }
        var receipt = try load(from: url) ?? PrivacyReceipt()
        let id: UUID?
        if receipt.attempts.count >= maximumAttempts {
            receipt.hasGaps = true
            if receipt.omittedAttempts < Int.max { receipt.omittedAttempts += 1 }
            id = nil
        } else {
            let attempt = PrivacyAttempt(id: UUID(), runID: runID, operation: operation, startedAt: Date())
            receipt.attempts.append(attempt)
            id = attempt.id
        }
        try save(receipt, to: url)
        return id
    }

    func finish(_ id: UUID, outcome: PrivacyAttempt.Outcome, at url: URL) throws {
        guard !isSuppressed(url) else { return }
        let url = resolvedURL(url)
        guard !isSuppressed(url) else { return }
        guard outcome != .started, var receipt = try load(from: url),
              let index = receipt.attempts.firstIndex(where: { $0.id == id }) else { throw StoreError.unknownAttempt }
        guard receipt.attempts[index].outcome == .started else {
            guard receipt.attempts[index].outcome == outcome else { throw StoreError.conflictingCompletion }
            return
        }
        receipt.attempts[index].outcome = outcome
        receipt.attempts[index].finishedAt = Date()
        try save(receipt, to: url)
    }

    private func receiptKey(_ url: URL) -> String {
        url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
    }

    private func resolvedURL(_ original: URL) -> URL {
        var url = original
        var seen = Set<String>()
        while seen.insert(receiptKey(url)).inserted, let next = aliases[receiptKey(url)] { url = next }
        return url
    }

    func preparePendingDirectory(at url: URL) throws {
        pendingRoots.insert(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// Install/merge evidence before redirecting any existing completion tokens.
    /// Replaying this after interruption cannot duplicate IDs or turn a finished
    /// attempt back into an uncertain start. Files stay untouched on conflict.
    func transfer(from original: URL, to destination: URL) throws {
        guard !isSuppressed(original) else { return }
        let source = resolvedURL(original), target = resolvedURL(destination)
        guard receiptKey(source) != receiptKey(target) else { return }
        if isSuppressed(target) {
            // A genuinely new recording may reuse a deleted filename. Only its
            // durable metadata identity can reopen that destination; a late
            // callback or viewer with the old identity cannot do so.
            let id = pendingID(source)
            let base = target.deletingPathExtension().deletingPathExtension()
            guard let id, PrivacyReceiptLifecycle.recordingID(for: base.appendingPathExtension("m4a")) == id,
                  try PrivacyReceiptLifecycle.hasSurvivingAudio(for: target) else { throw StoreError.deletedRecording }
            // A previous cleanup may have persisted its marker but failed to
            // remove the old receipt. Never merge that history into a new owner.
            try removeIfPresent(target)
            try removeIfPresent(gapURL(for: target))
            try removeIfPresent(deletionMarker(for: target))
            suppressedKeys.remove(receiptKey(target))
            unpersistedGaps.remove(receiptKey(target))
        }
        // Keep only a hash of the destination, beside the generated pending ID.
        // This survives failed binding/restart without recording private paths.
        if pendingID(source) != nil {
            pendingRoots.insert(source.deletingLastPathComponent())
            try writePrivately(Data(keyHash(target).utf8), to: bindingURL(for: source))
        }
        let incoming = try load(from: source)
        var merged = try load(from: target) ?? PrivacyReceipt()
        if let incoming {
            var attempts = Dictionary(uniqueKeysWithValues: merged.attempts.map { ($0.id, $0) })
            for entry in incoming.attempts {
                if let existing = attempts[entry.id] {
                    guard existing.operation == entry.operation, existing.runID == entry.runID,
                          existing.startedAt == entry.startedAt else { throw StoreError.invalidEvidence }
                    if existing.outcome == .started { attempts[entry.id] = entry }
                    else if entry.outcome != .started && existing.outcome != entry.outcome {
                        throw StoreError.conflictingCompletion
                    }
                } else { attempts[entry.id] = entry }
            }
            let ordered = attempts.values.sorted {
                $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
            }
            merged.attempts = Array(ordered.prefix(Self.maximumStoredAttempts))
            // Omission counts are lower bounds after merging overlapping
            // histories; using max keeps crash replay idempotent.
            merged.omittedAttempts = max(merged.omittedAttempts, incoming.omittedAttempts,
                                         ordered.count - merged.attempts.count)
            merged.hasGaps = merged.hasGaps || incoming.hasGaps || merged.omittedAttempts > 0
        }
        merged.hasGaps = merged.hasGaps || hasUnpersistedGap(at: source)
        if incoming != nil || merged.hasGaps { try save(merged, to: target) }
        let oldGap = gapURL(for: source)
        let oldKey = receiptKey(source)
        aliases[oldKey] = target
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: oldGap)
        unpersistedGaps.remove(oldKey)
    }

    private func gapURL(for url: URL) -> URL {
        gapDirectoryURL.appendingPathComponent(keyHash(url) + ".gap")
    }

    func noteGap(at url: URL) {
        guard !isSuppressed(url) else { return }
        let url = resolvedURL(url)
        guard !isSuppressed(url) else { return }
        unpersistedGaps.insert(receiptKey(url))
        // Independent of the recording's possibly offline/read-only folder.
        // The marker stores no URL, filename, content, provider or error text.
        do {
            try FileManager.default.createDirectory(at: gapDirectoryURL, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try writePrivately(Data([1]), to: gapURL(for: url))
        } catch {
            // If all storage is unavailable the live diagnostic remains. False
            // hasGaps must never be presented as proof of complete coverage.
        }
    }

    func hasUnpersistedGap(at url: URL) -> Bool {
        let url = resolvedURL(url)
        return unpersistedGaps.contains(receiptKey(url))
            || (try? FileManager.default.attributesOfItem(atPath: gapURL(for: url).path)) != nil
    }

    private func keyHash(_ url: URL) -> String {
        SHA256.hash(data: Data(receiptKey(url).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func pendingID(_ url: URL) -> UUID? {
        guard url.lastPathComponent.hasSuffix(".privacy.json") else { return nil }
        return UUID(uuidString: url.deletingPathExtension().deletingPathExtension().lastPathComponent)
    }

    private func bindingURL(for pending: URL) -> URL { pending.appendingPathExtension("binding") }
    func isPendingReceipt(_ url: URL) -> Bool {
        pendingID(url) != nil && pendingRoots.contains { receiptKey($0.appendingPathComponent("placeholder")) == receiptKey(url.deletingLastPathComponent().appendingPathComponent("placeholder")) }
    }
    private func deletionMarker(for url: URL) -> URL {
        gapDirectoryURL.appendingPathComponent(keyHash(url) + ".deleted")
    }

    private func isSuppressed(_ url: URL) -> Bool {
        suppressedKeys.contains(receiptKey(url))
            || (try? FileManager.default.attributesOfItem(atPath: deletionMarker(for: url).path)) != nil
    }

    private func associatedPendingURLs(for target: URL) -> [URL] {
        let hash = Data(keyHash(target).utf8)
        return pendingRoots.flatMap { root -> [URL] in
            let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
            return files.compactMap { file in
                guard file.pathExtension == "binding", pendingID(file.deletingPathExtension()) != nil,
                      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let handle = try? FileHandle(forReadingFrom: file) else { return nil }
                defer { try? handle.close() }
                guard (try? handle.read(upToCount: 65)) == hash else { return nil }
                return file.deletingPathExtension()
            }
        }
    }

    /// Collect before deleting metadata/recovery snapshots. Binding records also
    /// reconnect failed transfers after a restart, including old viewer scopes.
    func deletionTargets(for audioURL: URL, recordingIDs: Set<UUID> = []) -> [URL] {
        let target = PrivacyReceiptLifecycle.receiptURL(for: audioURL)
        var ids = recordingIDs
        if let id = PrivacyReceiptLifecycle.recordingID(for: audioURL) { ids.insert(id) }
        var urls = [target] + associatedPendingURLs(for: target)
        urls += pendingRoots.flatMap { root in ids.map { root.appendingPathComponent($0.uuidString + ".privacy.json") } }
        urls += aliases.keys.compactMap { key in receiptKey(resolvedURL(URL(fileURLWithPath: key))) == receiptKey(target) ? URL(fileURLWithPath: key) : nil }
        return Array(Set(urls))
    }

    /// Caller must first verify that all owned audio is gone. Suppression is
    /// durable before deleting files and remains even if cleanup partly fails.
    /// A retry can finish cleanup without any completion callback recreating it.
    func removeEvidence(at urls: [URL]) throws {
        let all = Set(urls + urls.map(resolvedURL))
        for url in all { suppressedKeys.insert(receiptKey(url)) }
        let keys = Set(all.map(receiptKey))
        // Old pending tokens are suppressed directly. Retaining aliases could
        // let a later cleanup retry follow one into a reused recording path.
        aliases = aliases.filter { !keys.contains($0.key) && !keys.contains(receiptKey($0.value)) }
        try FileManager.default.createDirectory(at: gapDirectoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for url in all { try writePrivately(Data([1]), to: deletionMarker(for: url)) }
        var failure: (any Error)?
        for url in all {
            do {
                try removeIfPresent(url)
                try removeIfPresent(gapURL(for: url))
                if pendingID(url) != nil { try removeIfPresent(bindingURL(for: url)) }
                unpersistedGaps.remove(receiptKey(url))
            } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    /// Retry app-owned remnants even when their final audio/receipt no longer
    /// exists for output-folder discovery. Deletion markers contain only hashes;
    /// pending file names contain generated IDs, never user recording names.
    func retryDeletedEvidenceCleanup() -> Int {
        var failures = 0
        for root in pendingRoots {
            let files: [URL]
            do { files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
            catch { failures += 1; continue }
            for file in files {
                let pending = file.pathExtension == "binding" ? file.deletingPathExtension() : file
                guard pendingID(pending) != nil, isSuppressed(pending) else { continue }
                do { try removeEvidence(at: [pending]) }
                catch { failures += 1 }
            }
        }
        do {
            let markers = try FileManager.default.contentsOfDirectory(at: gapDirectoryURL, includingPropertiesForKeys: nil)
            for marker in markers where marker.pathExtension == "deleted" {
                let hash = marker.deletingPathExtension().lastPathComponent
                guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { continue }
                do { try removeIfPresent(gapDirectoryURL.appendingPathComponent(hash + ".gap")) }
                catch { failures += 1 }
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
        catch { failures += 1 }
        return failures
    }

    private func removeIfPresent(_ url: URL) throws {
        do {
            let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeSymbolicLink else { throw StoreError.unsafeFile }
            try FileManager.default.removeItem(at: url)
        }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
    }

    private func save(_ value: PrivacyReceipt, to url: URL) throws {
        var receipt = value
        if hasUnpersistedGap(at: url) { receipt.hasGaps = true }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        guard data.count <= Self.maximumFileBytes else { throw StoreError.oversizedFile }
        try writePrivately(data, to: url)
        guard try load(from: url) == receipt else { throw StoreError.verificationFailed }
        // Only remove the independent marker after hasGaps is durable in the
        // sidecar itself. A crash between these steps keeps conservative evidence.
        try? FileManager.default.removeItem(at: gapURL(for: url))
        unpersistedGaps.remove(receiptKey(url))
    }

    private func writePrivately(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".privacy-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        // The temporary file is private from creation, before any bytes are
        // written. POSIX rename atomically installs it on the same filesystem.
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
