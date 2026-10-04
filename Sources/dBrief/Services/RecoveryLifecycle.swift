import Foundation

/// Deletes only app-owned, validated recovery records, never arbitrary paths
/// embedded in their payloads. Callers serialize this with processing/capture.
struct RecoveryLifecycle: Sendable {
    struct DeletionSnapshot: Sendable {
        var jobs: [UUID: UUID] = [:]
        var deliveries: [UUID: UUID] = [:]
        var recordingIDs: Set<UUID> { Set(jobs.values).union(deliveries.values) }
        var charge: Int { (jobs.count + deliveries.count) * 160 }
    }
    let jobs: ProcessingJobStore
    let deliveries: IntegrationDeliveryStore

    private func inventory() async throws -> ([PersistedProcessingJob], [IntegrationDeliveryBatch]) {
        let discovery = await jobs.discover()
        guard discovery.issues.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return (discovery.jobs, try await deliveries.discover())
    }

    func deletionSnapshot(for audioURL: URL, byteLimit: Int) async throws -> DeletionSnapshot {
        let jobIDs = try await jobs.deletionOwners(for: audioURL, byteLimit: byteLimit)
        let batches = try await deliveries.deletionOwners(for: audioURL, alsoIDs: Set(jobIDs.keys), byteLimit: byteLimit - jobIDs.count * 160)
        guard jobIDs.count + batches.count <= 128 else { throw LiveArtifactError.artifactTooLarge }
        return .init(jobs: jobIDs, deliveries: batches)
    }

    func removeSnapshots(for audioURL: URL, expected: DeletionSnapshot? = nil, authority: RecordingDeletionAuthority? = nil) async throws {
        if let expected, let authority {
            let current = try await deletionSnapshot(for: audioURL, byteLimit: RecordingDeletionAuthority.ticketLimit)
            guard current.jobs.allSatisfy({ expected.jobs[$0.key] == $0.value }),
                  current.deliveries.allSatisfy({ expected.deliveries[$0.key] == $0.value }) else { throw LiveArtifactError.wrongOwner }
            for (id, owner) in current.deliveries { try await deliveries.remove(id: id, expectedRecordingID: owner, authority: authority) }
            for (id, owner) in current.jobs { try await jobs.remove(id: id, expectedRecordingID: owner, authority: authority) }
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
    func privacyOwners() async throws -> [URL: Set<UUID>] {
        let (records, batches) = try await inventory()
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
    func prepareRetention(category: RetentionCategory, days: Int, folders: [URL], now: Date = Date()) async throws -> Set<String> {
        let (records, batches) = try await inventory()
        var protected = Set<String>()
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
            guard relevant else { continue }
            // Preserve successful processing dates before retiring the only
            // recovery copy. Failed metadata writes leave the journals intact.
            try await RecordingCompletionStore.reconcile(record)
            if let batch = batches.first(where: { $0.id == record.id }) {
                try await RecordingCompletionStore.reconcile(batch)
            }
            // Remove matching delivery content before its owning job snapshot.
            if batches.contains(where: { $0.id == record.id }) { try await deliveries.remove(id: record.id) }
            try await jobs.remove(id: record.id)
        }
        for batch in batches where !pendingDeliveryIDs.contains(batch.id) && !pendingIDs.contains(batch.id)
            && batch.createdAt < cutoff && inScope(batch.bundle.audioFileURL) {
            try await RecordingCompletionStore.reconcile(batch)
            try await deliveries.remove(id: batch.id)
        }
        return protected
    }

    private static func base(_ url: URL) -> String {
        // Resolve the existing parent, not the extensionless (usually absent)
        // stem: Foundation does not reliably resolve aliases of missing files.
        url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent).standardizedFileURL.path
    }

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
