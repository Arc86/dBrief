import Foundation
import dBriefWire

/// Runtime-only, remove-only authority. No writer, ledger or restart replay.
/// One serial worker owns the worksheet and mutable receipts; public callers
/// receive only counts. The registry's actual task retains the original owner.
actor LiveRAMTranscriptRetention {
    struct Selection: Sendable {
        let item: RecordingDeletionAuthority.Item
        let createdAt: Date
        let ordinaryChat: Bool
    }
    struct Inventory: Sendable {
        let folder: RecordingDeletionAuthority.Item
        let authority: RecordingDeletionAuthority?
        let selected: [Selection]
        let protections: [RecordingDeletionAuthority.Item]
        let dependencies: [URL: [RecordingDeletionAuthority.Item]]
        let cutoff: Date
        func validateScope() throws {
            try LiveSessionArtifactStore.requireSafeParents(folder.url.appendingPathComponent("probe"))
            guard try RecordingDeletionAuthority.Stamp.read(folder.url, directory: true) == folder.stamp else { throw LiveArtifactError.wrongOwner }
            try authority?.validateExact()
            for item in protections { try Self.exact(item) }
        }
        static func exact(_ item: RecordingDeletionAuthority.Item) throws {
            try LiveSessionArtifactStore.requireSafeParents(item.url)
            guard try RecordingDeletionAuthority.Stamp.read(item.url, directory: item.directory) == item.stamp else { throw LiveArtifactError.wrongOwner }
        }
        func validateOriginal() throws {
            try validateScope()
            for value in selected {
                try Self.exact(value.item)
                guard try Self.birth(value.item.url) == value.createdAt, value.createdAt < cutoff else { throw LiveArtifactError.wrongOwner }
                if value.ordinaryChat, try !RetentionOwnership.isOrdinaryChat(value.item.url) { throw LiveArtifactError.wrongOwner }
            }
            for values in dependencies.values { for item in values { try Self.exact(item) } }
        }
        func validateRemoved() throws {
            try validateScope()
            let removed = Set(selected.map { $0.item.url })
            for value in selected { try Self.absent(value.item.url) }
            for values in dependencies.values {
                for item in values {
                    if removed.contains(item.url) { try Self.absent(item.url) } else { try Self.exact(item) }
                }
            }
        }
        static func absent(_ url: URL) throws {
            try LiveSessionArtifactStore.requireSafeParents(url)
            guard try RecordingDeletionAuthority.Stamp.read(url) == nil else { throw LiveArtifactError.wrongOwner }
        }
        static func birth(_ url: URL) throws -> Date? { try url.resourceValues(forKeys: [.creationDateKey]).creationDate }
    }
    struct Progress: Sendable {
        var inventoryCount = 0, completedSteps = 0, removedFiles = 0, pendingSyncs = 0
        var bytesRemoved: Int64 = 0
        var cleanupComplete = false
    }
    private var inventory: Inventory?
    private var steps: [LiveHistoryRetention.Step] = []
    private var syncPending: Set<Int> = []
    private var progress = Progress()
    private let stage: @Sendable (LiveArtifactStage) async throws -> Void
    private let beforeSync: @Sendable (URL) throws -> Void
    init(stage: @escaping @Sendable (LiveArtifactStage) async throws -> Void,
         beforeSync: @escaping @Sendable (URL) throws -> Void) { self.stage = stage; self.beforeSync = beforeSync }
    func counts() -> Progress { progress }

    /// Each live scan owns its own bounds. A previously finite worksheet cannot
    /// bound filesystem growth before or during this second enumeration.
    private static func queuedBases(in folder: URL) throws -> Set<String> {
        try LiveSessionArtifactStore.requireSafeParents(folder.appendingPathComponent("probe"))
        guard try RecordingDeletionAuthority.Stamp.read(folder, directory: true) != nil else { throw LiveArtifactError.unsafePath }
        var failure: (any Error)?, visited = 0, pathBytes = 0
        guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else { throw LiveArtifactError.unsafePath }
        var bases = Set<String>()
        for case let url as URL in iterator {
            visited += 1
            guard visited <= 4_096 else { throw LiveArtifactError.artifactTooLarge }
            pathBytes += try RecordingDeletionAuthority.charge(url)
            guard pathBytes <= 512 * 1_024 else { throw LiveArtifactError.artifactTooLarge }
            guard url.lastPathComponent.lowercased().hasSuffix(".queue.json") else { continue }
            try LiveSessionArtifactStore.requireSafeParents(url)
            let base = try RecordingDeletionAuthority.canonical(url.deletingPathExtension().deletingPathExtension()).path
            guard bases.contains(base) || bases.count < 128 else { throw LiveArtifactError.artifactTooLarge }
            bases.insert(base)
        }
        if let failure { throw failure }
        return bases
    }

    func prepare(identity: LiveSessionIdentity, admittedAudio: URL?, capture: LiveRAMCaptureMetadata,
                 cutoff: Date, folders: [URL]) async throws -> Inventory? {
        guard inventory == nil else { throw LiveArtifactError.wrongOwner }
        // Association is chosen once. A missing associated B cannot use A.
        let candidate: URL
        if let audio = admittedAudio { candidate = audio.deletingLastPathComponent() }
        else if let intended = capture.intendedFolder { candidate = intended }
        else { return nil }
        let folder: RecordingDeletionAuthority.Item
        let authority: RecordingDeletionAuthority?
        do {
            try LiveSessionArtifactStore.requireSafeParents(candidate.appendingPathComponent("probe"))
            folder = try .init(candidate, directory: true)
            guard folder.stamp != nil,
                  try folders.contains(where: { try RecordingDeletionAuthority.canonical($0.appendingPathComponent("probe")).deletingLastPathComponent() == folder.url }) else { return nil }
            if let audio = admittedAudio {
                authority = try .init(audioURL: audio, expectedRecordingID: identity.recordingID)
                guard authority?.audio.stamp != nil, authority?.metadata.stamp != nil else { return nil }
            } else { authority = nil }
        } catch { return nil }
        let worksheet = RetentionOwnership(folders: [folder.url])
        // This worksheet remains inside the original closed owner's 24MiB
        // allowance through the real preparation callback, even after abandon.
        defer { withExtendedLifetime(worksheet) {} }
        guard !worksheet.inspectionFailed else { return nil }
        try await stage(.ramRetentionQueueScan)
        let queued = try Self.queuedBases(in: folder.url)
        var selected: [Selection] = [], protections: [RecordingDeletionAuthority.Item] = []
        var dependencies: [URL: [RecordingDeletionAuthority.Item]] = [:]
        if let authority {
            let master = authority.audioURL, base = master.deletingPathExtension()
            guard worksheet.recordingIDs[master] == identity.recordingID,
                  !worksheet.opaqueLiveBases.contains(base.path), !queued.contains(base.path) else { return nil }
            // Negative guards are closed evidence, never future deletion items.
            for suffix in ["queue.json", "live-binding.json", "live-transcript.json", "reprocessing.json"] {
                let item = try RecordingDeletionAuthority.Item(base.appendingPathExtension(suffix))
                guard item.stamp == nil else { return nil }; protections.append(item)
            }
            let allowed = Set(RetentionCleanup.transcriptSuffixes.filter {
                ![".md", ".reprocessing.json", ".live-transcript.json"].contains($0)
            }.map { URL(fileURLWithPath: base.path + $0) })
            let linked = Set((worksheet.dependencies[base.appendingPathExtension("insights.json")] ?? []).filter {
                $0.path.hasPrefix(folder.url.path + "/") && $0.pathExtension.lowercased() == "md"
            })
            for path in allowed.union(linked).sorted(by: { $0.path < $1.path }) {
                guard worksheet.owners[path] == [master], RetentionOwnership.isRegularUnlinked(path),
                      let birth = try Inventory.birth(path), birth.timeIntervalSinceReferenceDate.isFinite, birth < cutoff else { continue }
                let chat = path.lastPathComponent.hasSuffix(".chat.json")
                if chat, try !RetentionOwnership.isOrdinaryChat(path) { continue }
                selected.append(.init(item: try .init(path), createdAt: birth, ordinaryChat: chat))
            }
            let paths = Set(selected.map { $0.item.url })
            selected = try selected.filter { value in
                let children = worksheet.dependencies[value.item.url] ?? []
                var guards: [RecordingDeletionAuthority.Item] = []
                for child in children {
                    guard child.path.hasPrefix(folder.url.path + "/"), worksheet.owners[child] == [master] else { return false }
                    let item = try RecordingDeletionAuthority.Item(child)
                    guard item.stamp == nil || paths.contains(item.url) else { return false }
                    guards.append(item)
                }
                if !guards.isEmpty { dependencies[value.item.url] = guards }
                return true
            }
            // Only the linked Markdown precedes its ownership proof. All other
            // steps use deterministic paths; this is not a new folder sweep.
            selected.sort { a, b in
                if a.item.url.pathExtension == "md", b.item.url.pathExtension != "md" { return true }
                if b.item.url.pathExtension == "md", a.item.url.pathExtension != "md" { return false }
                return a.item.url.path < b.item.url.path
            }
        } else {
            guard worksheet.opaqueLiveBases.isEmpty, queued.isEmpty else { return nil }
        }
        let dependentItems = dependencies.values.flatMap { $0 }
        guard selected.count + protections.count + dependentItems.count <= 128 else { throw LiveArtifactError.artifactTooLarge }
        // Capture may have no folder. All copies/path/date/control witnesses are
        // charged before publication under the separate 224KiB maintenance.
        var charge = 1_024 + (capture.intendedFolder?.absoluteString.utf8.count ?? 0) * 6
        for item in [folder] + (authority.map { [$0.audio, $0.metadata] } ?? []) + protections + dependentItems + selected.map(\.item) {
            charge += try RecordingDeletionAuthority.charge(item.url) + 192
        }
        guard charge <= RecordingDeletionAuthority.ticketLimit else { throw LiveArtifactError.artifactTooLarge }
        let value = Inventory(folder: folder, authority: authority, selected: selected, protections: protections, dependencies: dependencies, cutoff: cutoff)
        try RecordingResultMutation.withTransaction { try value.validateOriginal() }
        try await stage(.ramRetentionPrepared)
        return value
    }
    func install(_ value: Inventory) throws {
        guard inventory == nil else { throw LiveArtifactError.wrongOwner }
        inventory = value
        steps = value.selected.map { .init(original: $0.item, effect: .remove, revision: nil) }
        progress.inventoryCount = steps.count
    }
    private func validateProgress(_ value: Inventory) throws {
        try value.validateScope()
        let completed = Set(steps.filter(\.completed).map { $0.original.url })
        for step in steps where step.completed { try Inventory.absent(step.original.url) }
        for guards in value.dependencies.values {
            for item in guards {
                if completed.contains(item.url) { try Inventory.absent(item.url) } else { try Inventory.exact(item) }
            }
        }
    }
    func cleanup() async throws {
        guard let value = inventory else { throw LiveArtifactError.missingEvidence }
        for index in steps.indices {
            try await stage(.retentionRemoval)
            let effect = {
                try self.validateProgress(value)
                if self.steps[index].completed {
                    if self.syncPending.contains(index) {
                        try self.beforeSync(self.steps[index].original.url.deletingLastPathComponent())
                        try LiveSessionArtifactStore.synchronizeRetainedDirectory(self.steps[index].original.url.deletingLastPathComponent())
                        self.syncPending.remove(index); self.progress.pendingSyncs = self.syncPending.count
                    }
                    return
                }
                let selected = value.selected[index], item = selected.item
                // A missing selected original is idempotent, but never counts
                // as an actual physical unlink and cannot gain a replacement.
                if try RecordingDeletionAuthority.Stamp.read(item.url) == nil {
                    self.steps[index].completed = true; self.progress.completedSteps += 1; return
                }
                try Inventory.exact(item)
                guard try Inventory.birth(item.url) == selected.createdAt else { throw LiveArtifactError.wrongOwner }
                if selected.ordinaryChat, try !RetentionOwnership.isOrdinaryChat(item.url) { throw LiveArtifactError.wrongOwner }
                try LiveSessionArtifactStore.unlinkRetained(item, didUnlink: {
                    self.steps[index].completed = true; self.steps[index].result = nil
                    self.syncPending.insert(index)
                    self.progress.completedSteps += 1; self.progress.removedFiles += 1
                    self.progress.bytesRemoved += item.stamp?.size ?? 0; self.progress.pendingSyncs = self.syncPending.count
                }, beforeSync: self.beforeSync)
                self.syncPending.remove(index); self.progress.pendingSyncs = self.syncPending.count
            }
            if let authority = value.authority { try RecordingResultMutation.withDeletion(of: authority.audioURL, effect) }
            else { try RecordingResultMutation.withTransaction(effect) }
            try await stage(.ramRetentionRemoved)
        }
        try await stage(.retentionCompleted)
        try RecordingResultMutation.withTransaction {
            try validateProgress(value); try value.validateRemoved()
            guard syncPending.isEmpty else { throw LiveArtifactError.verificationFailed }
            progress.cleanupComplete = true
        }
    }
}
