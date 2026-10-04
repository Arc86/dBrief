import Foundation

/// Deletes only app-owned, validated recovery records, never arbitrary paths
/// embedded in their payloads. Callers serialize this with processing/capture.
struct RecoveryLifecycle: Sendable {
    struct DeletionSnapshot: Codable, Sendable {
        var jobs: [UUID: UUID] = [:]
        var deliveries: [UUID: UUID] = [:]
        var retentionJobs: [UUID: RecoveryRetentionAuthority]? = nil
        var retentionDeliveries: [UUID: RecoveryRetentionAuthority]? = nil
        init(jobs: [UUID: UUID] = [:], deliveries: [UUID: UUID] = [:],
             retentionJobs: [UUID: RecoveryRetentionAuthority]? = nil,
             retentionDeliveries: [UUID: RecoveryRetentionAuthority]? = nil) {
            self.jobs = jobs; self.deliveries = deliveries
            self.retentionJobs = retentionJobs; self.retentionDeliveries = retentionDeliveries
        }
        private enum CodingKeys: String, CodingKey { case jobs, deliveries, retentionJobs, retentionDeliveries }
        private struct Entry<Value: Codable>: Codable { let id: UUID; let value: Value }
        /// UUID-key dictionaries otherwise encode as randomly ordered JSON
        /// arrays, which cannot serve as a durable deletion receipt digest.
        private static func entries<Value: Codable>(_ values: [UUID: Value]) -> [Entry<Value>] {
            values.keys.sorted { $0.uuidString < $1.uuidString }.map { Entry(id: $0, value: values[$0]!) }
        }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.entries(jobs), forKey: .jobs)
            try container.encode(Self.entries(deliveries), forKey: .deliveries)
            if let retentionJobs { try container.encode(Self.entries(retentionJobs), forKey: .retentionJobs) }
            if let retentionDeliveries { try container.encode(Self.entries(retentionDeliveries), forKey: .retentionDeliveries) }
        }
        private static func values<Value: Codable>(_ type: Value.Type, from decoder: any Decoder) throws -> [UUID: Value] {
            var result: [UUID: Value] = [:]
            if let entries = try? [Entry<Value>](from: decoder) {
                guard entries.count <= 128 else { throw LiveArtifactError.artifactTooLarge }
                for entry in entries {
                    guard result.updateValue(entry.value, forKey: entry.id) == nil else { throw LiveArtifactError.wrongOwner }
                }
            } else {
                // Version1/2 tickets used alternating UUID/value arrays.
                var container = try decoder.unkeyedContainer()
                while !container.isAtEnd {
                    guard result.count < 128 else { throw LiveArtifactError.artifactTooLarge }
                    let id = try container.decode(UUID.self), value = try container.decode(Value.self)
                    guard result.updateValue(value, forKey: id) == nil else { throw LiveArtifactError.wrongOwner }
                }
            }
            return result
        }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            jobs = container.contains(.jobs) ? try Self.values(UUID.self, from: container.superDecoder(forKey: .jobs)) : [:]
            deliveries = container.contains(.deliveries) ? try Self.values(UUID.self, from: container.superDecoder(forKey: .deliveries)) : [:]
            if container.contains(.retentionJobs), try !container.decodeNil(forKey: .retentionJobs) {
                retentionJobs = try Self.values(RecoveryRetentionAuthority.self, from: container.superDecoder(forKey: .retentionJobs))
            } else { retentionJobs = nil }
            if container.contains(.retentionDeliveries), try !container.decodeNil(forKey: .retentionDeliveries) {
                retentionDeliveries = try Self.values(RecoveryRetentionAuthority.self, from: container.superDecoder(forKey: .retentionDeliveries))
            } else { retentionDeliveries = nil }
        }
        var recordingIDs: Set<UUID> { Set(jobs.values).union(deliveries.values) }
        var charge: Int { (jobs.count + deliveries.count) * 160
            + (retentionJobs?.values.reduce(0) { $0 + $1.charge } ?? 0)
            + (retentionDeliveries?.values.reduce(0) { $0 + $1.charge } ?? 0) }
        func validateRetention() throws {
            guard let retentionJobs, let retentionDeliveries,
                  Set(retentionJobs.keys) == Set(jobs.keys), Set(retentionDeliveries.keys) == Set(deliveries.keys),
                  jobs.count + deliveries.count <= 128, charge <= RecordingDeletionAuthority.ticketLimit else { throw LiveArtifactError.wrongOwner }
            for value in Array(retentionJobs.values) + Array(retentionDeliveries.values) { try value.validateShape() }
        }
    }
    let jobs: ProcessingJobStore
    let deliveries: IntegrationDeliveryStore

    private func inventory(bounded: Bool = false) async throws -> ([PersistedProcessingJob], [IntegrationDeliveryBatch]) {
        if bounded { return (try await jobs.discoverForRetention(), try await deliveries.discoverForRetention()) }
        let discovery = await jobs.discover()
        guard discovery.issues.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return (discovery.jobs, try await deliveries.discover())
    }

    func deletionSnapshot(for audioURL: URL, byteLimit: Int, retention: Bool = false) async throws -> DeletionSnapshot {
        if retention {
            let path = try RecordingDeletionAuthority.canonical(audioURL)
            let frozenJobs = try await jobs.retentionInventory(), frozenBatches = try await deliveries.retentionInventory()
            let matchingJobs = try frozenJobs.filter { try $0.value.source.finalizedAudioPath.map { try RecordingDeletionAuthority.canonical(URL(fileURLWithPath: $0)) } == path }
            let owners = Dictionary(uniqueKeysWithValues: matchingJobs.map { ($0.value.id, $0.value.recordingID) })
            let owner = try RecordingDeletionAuthority(audioURL: audioURL).recordingID
            guard owner == nil || matchingJobs.allSatisfy({ $0.value.recordingID == owner }) else { throw LiveArtifactError.wrongOwner }
            let matchingBatches = try frozenBatches.filter {
                let batch = $0.value, audio = try RecordingDeletionAuthority.canonical(batch.bundle.audioFileURL)
                if let pairedOwner = owners[batch.id] {
                    guard audio == path, batch.recordingID == pairedOwner else { throw LiveArtifactError.wrongOwner }
                }
                guard audio == path else { return false }
                guard owner == nil || batch.recordingID == owner else { throw LiveArtifactError.wrongOwner }
                return true
            }
            let snapshot = DeletionSnapshot(jobs: Dictionary(uniqueKeysWithValues: matchingJobs.map { ($0.value.id, $0.value.recordingID) }),
                deliveries: Dictionary(uniqueKeysWithValues: matchingBatches.map { ($0.value.id, $0.value.recordingID) }),
                retentionJobs: Dictionary(uniqueKeysWithValues: matchingJobs.map { ($0.value.id, $0.authority) }),
                retentionDeliveries: Dictionary(uniqueKeysWithValues: matchingBatches.map { ($0.value.id, $0.authority) }))
            try snapshot.validateRetention()
            guard snapshot.charge <= byteLimit else { throw LiveArtifactError.artifactTooLarge }
            return snapshot
        }
        let jobIDs = try await jobs.deletionOwners(for: audioURL, byteLimit: byteLimit, retention: retention)
        let batches = try await deliveries.deletionOwners(for: audioURL, alsoIDs: Set(jobIDs.keys), byteLimit: byteLimit - jobIDs.count * 160, retention: retention)
        guard jobIDs.count + batches.count <= 128 else { throw LiveArtifactError.artifactTooLarge }
        return .init(jobs: jobIDs, deliveries: batches)
    }

    func removeSnapshots(for audioURL: URL, expected: DeletionSnapshot? = nil, authority: RecordingDeletionAuthority? = nil, retention: Bool = false) async throws {
        if let expected, let authority {
            let current = try await deletionSnapshot(for: audioURL, byteLimit: RecordingDeletionAuthority.ticketLimit, retention: retention)
            guard current.jobs.allSatisfy({ expected.jobs[$0.key] == $0.value }),
                  current.deliveries.allSatisfy({ expected.deliveries[$0.key] == $0.value }) else { throw LiveArtifactError.wrongOwner }
            if retention {
                try expected.validateRetention()
                // A partial recursive unlink may remove the manifest first.
                // Replay frozen IDs even when discovery can no longer see them.
                for (id, owner) in expected.deliveries { try await deliveries.removeForRetention(id: id, expectedRecordingID: owner, expected: expected.retentionDeliveries![id]!, audioAuthority: authority) }
                for (id, owner) in expected.jobs { try await jobs.removeForRetention(id: id, expectedRecordingID: owner, expected: expected.retentionJobs![id]!, audioAuthority: authority) }
                return
            }
            for (id, owner) in current.deliveries { try await deliveries.remove(id: id, expectedRecordingID: owner, authority: authority, retention: retention) }
            for (id, owner) in current.jobs { try await jobs.remove(id: id, expectedRecordingID: owner, authority: authority, retention: retention) }
            return
        }
        let (records, batches) = try await inventory()
        let path = audioURL.resolvingSymlinksInPath().standardizedFileURL.path
        let matching = records.filter {
            $0.source.finalizedAudioPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path } == path
        }
        let ids = Set(matching.map(\.id))
        let matchingBatches = batches.filter { ids.contains($0.id) || $0.bundle.audioFileURL.resolvingSymlinksInPath().standardizedFileURL.path == path }
        if let expected {
            guard matching.allSatisfy({ expected.jobs[$0.id] == $0.recordingID }),
                  matchingBatches.allSatisfy({ expected.deliveries[$0.id] == $0.recordingID }) else { throw LiveArtifactError.wrongOwner }
        }
        for batch in matchingBatches {
            try await deliveries.remove(id: batch.id, expectedRecordingID: expected?.deliveries[batch.id], authority: authority)
        }
        for record in matching { try await jobs.remove(id: record.id, expectedRecordingID: expected?.jobs[record.id], authority: authority) }
    }

    /// Read before retention/deletion retires durable recovery ownership.
    func privacyOwners(bounded: Bool = false) async throws -> [URL: Set<UUID>] {
        let (records, batches) = try await inventory(bounded: bounded)
        var owners: [URL: Set<UUID>] = [:]
        for record in records {
            if let path = record.source.finalizedAudioPath {
                owners[URL(fileURLWithPath: path).standardizedFileURL, default: []].insert(record.recordingID)
            }
        }
        for batch in batches {
            owners[batch.bundle.audioFileURL.standardizedFileURL, default: []].insert(batch.recordingID)
        }
        return owners
    }

    /// Unfinished work is protected across both output folders even after its
    /// legacy queue marker was retired. Dismissed/completed snapshots age out.
    func prepareRetention(category: RetentionCategory, days: Int, folders: [URL], now: Date = Date(), protectedBases: Set<String> = [], bounded: Bool = false) async throws -> Set<String> {
        let frozenJobs = bounded ? try await jobs.retentionInventory() : []
        let frozenBatches = bounded ? try await deliveries.retentionInventory() : []
        let records: [PersistedProcessingJob], batches: [IntegrationDeliveryBatch]
        if bounded { records = frozenJobs.map(\.value); batches = frozenBatches.map(\.value) }
        else { (records, batches) = try await inventory() }
        let jobAuthority = Dictionary(uniqueKeysWithValues: frozenJobs.map { ($0.value.id, $0.authority) })
        let batchAuthority = Dictionary(uniqueKeysWithValues: frozenBatches.map { ($0.value.id, $0.authority) })
        var protected = Set(protectedBases.map { RetentionCleanup.canonicalBase(URL(fileURLWithPath: $0)) })
        let pendingDeliveryIDs = Set(batches.filter { !$0.isComplete && $0.dismissedFromQueue != true }.map(\.id))
        let completedDeliveryIDs = Set(batches.filter(\.isComplete).map(\.id))
        let pendingRecords = records.filter {
            let finished = $0.status == .completed || ($0.checkpoint.hasCompleted(.markdownGenerated) && completedDeliveryIDs.contains($0.id))
            return (!finished && $0.dismissedFromQueue != true) || pendingDeliveryIDs.contains($0.id)
        }
        for record in pendingRecords {
            if let path = record.source.finalizedAudioPath { protected.insert(Self.base(URL(fileURLWithPath: path))) }
            for path in record.source.segmentAudioPaths { protected.insert(Self.base(URL(fileURLWithPath: path))) }
            if let url = record.markdownExport?.destination { protected.insert(Self.base(url)) }
        }
        for batch in batches where pendingDeliveryIDs.contains(batch.id) {
            protected.insert(Self.base(batch.bundle.audioFileURL))
        }
        guard days >= 0 else { return protected }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let pendingIDs = Set(pendingRecords.map(\.id))
        func inScope(_ url: URL) -> Bool {
            folders.contains { url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") }
        }
        for record in records where !pendingIDs.contains(record.id) && record.createdAt < cutoff {
            let audio = record.source.finalizedAudioPath.map { URL(fileURLWithPath: $0) }
            let relevant = audio.map(inScope) == true || (category == .transcripts && record.markdownExport.map { inScope($0.destination) } == true)
            guard relevant, audio.map({ !protected.contains(Self.base($0)) }) ?? true else { continue }
            // Preserve successful processing dates before retiring the only
            // recovery copy. Failed metadata writes leave the journals intact.
            try await RecordingCompletionStore.reconcile(record, retention: bounded)
            if let batch = batches.first(where: { $0.id == record.id }) {
                try await RecordingCompletionStore.reconcile(batch, retention: bounded)
            }
            // Remove matching delivery content before its owning job snapshot.
            if let batch = batches.first(where: { $0.id == record.id }) {
                if bounded { try await deliveries.removeForRetention(id: record.id, expectedRecordingID: batch.recordingID, expected: batchAuthority[record.id]!) }
                else { try await deliveries.remove(id: record.id) }
            }
            if bounded { try await jobs.removeForRetention(id: record.id, expectedRecordingID: record.recordingID, expected: jobAuthority[record.id]!) }
            else { try await jobs.remove(id: record.id) }
        }
        for batch in batches where !pendingDeliveryIDs.contains(batch.id) && !pendingIDs.contains(batch.id)
            && batch.createdAt < cutoff && inScope(batch.bundle.audioFileURL) && !protected.contains(Self.base(batch.bundle.audioFileURL)) {
            try await RecordingCompletionStore.reconcile(batch, retention: bounded)
            if bounded { try await deliveries.removeForRetention(id: batch.id, expectedRecordingID: batch.recordingID, expected: batchAuthority[batch.id]!) }
            else { try await deliveries.remove(id: batch.id) }
        }
        // Keep the legacy public spelling for conventional callers. Retention's
        // bounded manager path uses physical canonical bases throughout.
        return bounded ? protected : Set(protected.map { RetentionCleanup.legacyBase(URL(fileURLWithPath: $0)) })
    }

    func pendingRetentionBases() async throws -> Set<String> {
        let (records, batches) = try await inventory(bounded: true)
        let pendingDeliveryIDs = Set(batches.filter { !$0.isComplete && $0.dismissedFromQueue != true }.map(\.id))
        let completedDeliveryIDs = Set(batches.filter(\.isComplete).map(\.id))
        var protected = Set<String>()
        for record in records {
            let finished = record.status == .completed || (record.checkpoint.hasCompleted(.markdownGenerated) && completedDeliveryIDs.contains(record.id))
            guard (!finished && record.dismissedFromQueue != true) || pendingDeliveryIDs.contains(record.id) else { continue }
            if let path = record.source.finalizedAudioPath { protected.insert(Self.base(URL(fileURLWithPath: path))) }
            for path in record.source.segmentAudioPaths { protected.insert(Self.base(URL(fileURLWithPath: path))) }
            if let url = record.markdownExport?.destination { protected.insert(Self.base(url)) }
        }
        for batch in batches where pendingDeliveryIDs.contains(batch.id) { protected.insert(Self.base(batch.bundle.audioFileURL)) }
        return protected
    }

    private static func base(_ url: URL) -> String { RetentionCleanup.canonicalBase(url.deletingPathExtension()) }

    func dismiss(id: UUID) async throws {
        let savedRecord = try await jobs.load(id: id)
        let savedBatch = try await deliveries.load(id: id)
        if var record = savedRecord {
            record.markCancelled(at: Date())
            record.dismissedFromQueue = true
            try await jobs.save(record)
        }
        if var batch = savedBatch {
            batch.dismissedFromQueue = true
            try await deliveries.save(batch)
        }
    }
}

/// A retention record's UUID is descriptive; this physical inventory authorizes
/// its removal. A same-byte manifest replacement or new scratch child is foreign.
struct RecoveryRetentionRecord<Value: Sendable>: Sendable {
    let value: Value
    let authority: RecoveryRetentionAuthority
}
struct RecoveryRetentionAuthority: Codable, Sendable {
    let manifest: RecordingDeletionAuthority.Item
    let directory: RecordingDeletionAuthority.Item?
    let children: [RecordingDeletionAuthority.Item]
    init(manifest: RecordingDeletionAuthority.Item, directory: URL? = nil) throws {
        self.manifest = manifest
        self.directory = try directory.map { try RecordingDeletionAuthority.Item($0, directory: true) }
        var children: [RecordingDeletionAuthority.Item] = [], charge = try RecordingDeletionAuthority.charge(manifest.url)
        if let directory {
            try RecordingDeletionAuthority.scanChildren(directory, includeHidden: true) { url in
                let item = try RecordingDeletionAuthority.Item(url)
                charge += try RecordingDeletionAuthority.charge(item.url)
                guard children.count < 128, charge <= RecordingDeletionAuthority.ticketLimit else { throw LiveArtifactError.artifactTooLarge }
                children.append(item)
            }
        }
        self.children = children
        guard try RecordingDeletionAuthority.Stamp.read(manifest.url) == manifest.stamp else { throw LiveArtifactError.wrongOwner }
    }
    var charge: Int {
        512 + ([manifest] + (directory.map { [$0] } ?? []) + children).reduce(0) { $0 + 160 + $1.url.absoluteString.utf8.count * 6 }
    }
    func validateShape() throws {
        guard !manifest.directory, manifest.stamp != nil, children.count <= 128, charge <= RecordingDeletionAuthority.ticketLimit,
              directory?.directory != false, directory == nil || directory?.stamp != nil, Set(children.map(\.url)).count == children.count,
              directory != nil || children.isEmpty else { throw LiveArtifactError.wrongOwner }
        for item in [manifest] + (directory.map { [$0] } ?? []) + children {
            let canonical = try RecordingDeletionAuthority.canonical(item.url)
            // Foundation changes the directory slash spelling after removal.
            // Both exact physical directory spellings keep the same authority.
            guard item.url == canonical || (item.directory && item.url == URL(fileURLWithPath: canonical.path, isDirectory: true)) else { throw LiveArtifactError.unsafePath }
        }
        if let directory {
            guard manifest.url.deletingLastPathComponent() == directory.url,
                  children.contains(where: { $0.url == manifest.url }), children.allSatisfy({ !$0.directory && $0.url.deletingLastPathComponent() == directory.url }) else { throw LiveArtifactError.wrongOwner }
        }
    }
    func validate() throws {
        try validateShape()
        // An already removed original directory is idempotent while its
        // private store parent must still be available and safe.
        let parent = (directory?.url ?? manifest.url).deletingLastPathComponent()
        try RecordingDeletionAuthority.scanChildren(parent, includeHidden: true, requireRoot: true) { _ in }
        try LiveSessionArtifactStore.requireSafeParents(directory?.url ?? manifest.url)
        try manifest.validate()
        if let directory {
            try directory.validate()
            let paths = Set(children.map(\.url))
            try RecordingDeletionAuthority.scanChildren(directory.url, includeHidden: true) { url in
                guard paths.contains(try RecordingDeletionAuthority.canonical(url)) else { throw LiveArtifactError.wrongOwner }
            }
            for child in children { try child.validate() }
        }
    }
}
