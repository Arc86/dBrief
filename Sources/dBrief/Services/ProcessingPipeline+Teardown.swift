import Foundation

extension ProcessingPipeline {
    struct TeardownRequest: Sendable {
        let completed: Bool
        let processingSucceeded: Bool
        let record: PersistedProcessingJob?
        let completion: ProcessingCompletionStamp?
        let queuedAudioURL: URL?
    }
    enum TeardownWarning: Sendable { case journal, metadata }
    struct TeardownSteps: Sendable {
        var saveRecord: @Sendable (PersistedProcessingJob) async throws -> Void
        var publishRecord: @Sendable (PersistedProcessingJob) async throws -> Void
        var saveCompletion: @Sendable (ProcessingCompletionStamp) async throws -> Void
        var removeQueue: @Sendable (URL) async -> Void = { audioURL in
            let url = audioURL.deletingPathExtension().appendingPathExtension("queue.json")
            try? FileManager.default.removeItem(at: url)
            RecordingLibraryChange.notify()
        }
        var warning: @Sendable (TeardownWarning) async throws -> Void
        var validateOwnership: @Sendable () async throws -> Void = {}
    }

    /// Persist completion evidence before retiring the legacy queue marker.
    /// Failed/held workflows preserve their retry inputs. The caller releases UI
    /// ownership only after this returns to the same active job.
    func teardown(_ request: TeardownRequest, steps: TeardownSteps) async throws {
        try await validateTeardownOwner(steps)
        guard request.completed else { return }
        if var record = request.record {
            record.markFullyCompleted(at: request.completion?.completedAt ?? now(),
                successful: request.processingSucceeded && request.completion != nil)
            do {
                try await steps.saveRecord(record)
                try await validateTeardownOwner(steps)
                try await steps.publishRecord(record)
                try await validateTeardownOwner(steps)
            } catch {
                try await validateTeardownOwner(steps)
                try await steps.warning(.journal)
                try await validateTeardownOwner(steps)
            }
        }
        if request.processingSucceeded, let completion = request.completion {
            do {
                try await steps.saveCompletion(completion)
                try await validateTeardownOwner(steps)
            } catch {
                try await validateTeardownOwner(steps)
                try await steps.warning(.metadata)
                try await validateTeardownOwner(steps)
            }
        }
        if let audioURL = request.queuedAudioURL {
            await steps.removeQueue(audioURL)
            try await validateTeardownOwner(steps)
        }
    }

    private func validateTeardownOwner(_ steps: TeardownSteps) async throws {
        try Task.checkCancellation()
        try await steps.validateOwnership()
        try Task.checkCancellation()
    }
}
