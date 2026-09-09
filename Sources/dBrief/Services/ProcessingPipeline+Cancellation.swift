import Foundation
import dBriefWire

extension ProcessingPipeline {
    struct CancellationSnapshot: Sendable {
        let jobID: UUID
        var source: PersistedProcessingJob.Source
        var fallbackRecord: PersistedProcessingJob?
        let queuedAudioURL: URL?
        let transcriptURL: URL?
        let fallbackQueueItem: QueueItem
    }
    enum CancellationWarning: Sendable { case journal, queue }
    struct CancellationSteps: Sendable {
        var releaseResources: @Sendable () async -> Void
        var waitForJob: @Sendable () async -> Void
        var snapshot: @Sendable () async throws -> CancellationSnapshot
        var loadRecord: @Sendable (UUID) async throws -> PersistedProcessingJob?
        var saveRecord: @Sendable (PersistedProcessingJob) async throws -> Void
        var publishRecord: @Sendable (PersistedProcessingJob) async throws -> Void
        var registerQueueFolder: @Sendable (URL) async throws -> Void
        var warning: @Sendable (CancellationWarning) async throws -> Void
        var validateOwnership: @Sendable () async throws -> Void = {}
    }
    struct CancellationFiles: Sendable {
        var readQueue: @Sendable (URL) throws -> QueueItem? = { url in
            do { return try QueueItem.load(from: url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        }
        var writeQueue: @Sendable (QueueItem, URL) async throws -> Void = { item, url in
            let bytes = try JSONEncoder().encode(item)
            try bytes.write(to: url, options: .atomic)
            guard try Data(contentsOf: url) == bytes else { throw CocoaError(.fileWriteUnknown) }
            RecordingLibraryChange.notify()
        }
    }

    /// Stop cleanup deliberately outlives cancellation of its caller. Ownership,
    /// not Task cancellation, gates this workflow. The cancelled processing task
    /// must finish adopting committed artifacts before its recovery state is read.
    func cancelWorkflow(steps: CancellationSteps, files: CancellationFiles = .init()) async throws {
        try await steps.validateOwnership()
        await steps.releaseResources()
        try await steps.validateOwnership()
        await steps.waitForJob()
        try await steps.validateOwnership()
        let input = try await steps.snapshot()
        try await steps.validateOwnership()
        var latest = input.fallbackRecord
        do {
            // Initial creation may have committed without publishing back to the job.
            latest = try await steps.loadRecord(input.jobID) ?? input.fallbackRecord
            try await steps.validateOwnership()
            if var record = latest {
                guard record.id == input.jobID else { throw CocoaError(.coderReadCorrupt) }
                record.source = cancellationSource(input.source, retaining: record.source, fallbackProfileID: input.fallbackQueueItem.profileID)
                record.markCancelled(at: now())
                try await steps.saveRecord(record)
                try await steps.validateOwnership()
                latest = record
                try await steps.publishRecord(record)
                try await steps.validateOwnership()
            }
        } catch {
            try await steps.validateOwnership()
            try await steps.warning(.journal)
            try await steps.validateOwnership()
        }

        guard let audioURL = input.queuedAudioURL
                ?? (input.source.finalizedAudioPath ?? latest?.source.finalizedAudioPath).map(URL.init(fileURLWithPath:))
        else { return }
        let markerURL = audioURL.deletingPathExtension().appendingPathExtension("queue.json")
        let transcriptURL = input.transcriptURL
            ?? audioURL.deletingPathExtension().appendingPathExtension("transcript.json")
        // This is cleanup, so a cancelled Stop caller must not turn a saved
        // transcript into a false "missing" result via loadTranscript's task guard.
        let savedTranscript = (try? transcriptFiles.read(transcriptURL))
            .flatMap { try? JSONDecoder().decode(TranscriptionResult.self, from: $0) }
        var fallback = input.fallbackQueueItem
        if let record = latest {
            fallback = QueueItem(id: input.jobID, transcribe: record.request.transcribe,
                summary: record.request.summary, actionItems: record.request.actionItems,
                tags: record.request.tags, titleWasUserProvided: record.request.titleWasUserProvided,
                autoQueued: false, profileID: record.source.profileID ?? fallback.profileID)
        }
        do {
            guard try cancellationQueueItem(at: markerURL, jobID: input.jobID,
                fallback: fallback, hasTranscript: savedTranscript != nil, files: files) != nil else { return }
            try await steps.registerQueueFolder(audioURL.deletingLastPathComponent())
            try await steps.validateOwnership()
            // Folder registration suspends. Preserve any newer marker options and
            // reject a replacement identity instead of overwriting its bytes.
            guard let item = try cancellationQueueItem(at: markerURL, jobID: input.jobID,
                fallback: fallback, hasTranscript: savedTranscript != nil, files: files) else { return }
            try await files.writeQueue(item, markerURL)
            try await steps.validateOwnership()
        } catch {
            try await steps.validateOwnership()
            try await steps.warning(.queue)
            try await steps.validateOwnership()
        }
    }

    private func cancellationQueueItem(at url: URL, jobID: UUID, fallback: QueueItem,
                                       hasTranscript: Bool, files: CancellationFiles) throws -> QueueItem? {
        if var existing = try files.readQueue(url) {
            guard existing.id == jobID else { throw CocoaError(.coderReadCorrupt) }
            existing.autoQueued = false
            return existing
        }
        guard !hasTranscript else { return nil }
        var item = fallback
        item.id = jobID
        item.autoQueued = false
        return item
    }

    /// Durable paths can be newer than Recording when an awaited checkpoint or
    /// initial staging operation commits just as Stop clears processing ownership.
    private func cancellationSource(_ snapshot: PersistedProcessingJob.Source,
                                    retaining durable: PersistedProcessingJob.Source,
                                    fallbackProfileID: UUID?) -> PersistedProcessingJob.Source {
        var source = snapshot
        source.profileID = durable.profileID ?? fallbackProfileID ?? snapshot.profileID
        if source.finalizedAudioPath == nil {
            source.finalizedAudioPath = durable.finalizedAudioPath
            if source.segmentAudioPaths.isEmpty { source.segmentAudioPaths = durable.segmentAudioPaths }
            source.metadataPath = source.metadataPath ?? durable.metadataPath
            source.stagedInputPath = source.stagedInputPath ?? durable.stagedInputPath
            source.recoveryManifestPath = source.recoveryManifestPath ?? durable.recoveryManifestPath
            if source.fileSize <= 0 { source.fileSize = durable.fileSize }
            if source.duration <= 0 { source.duration = durable.duration }
        }
        return source
    }
}
