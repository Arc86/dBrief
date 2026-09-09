import Foundation

extension ProcessingPipeline {
    func updateMetadata(_ update: RecordingMetadataStore.Update, audioURL: URL) async throws {
        try Task.checkCancellation()
        try await metadataStore.update(update, audioURL: audioURL)
        try Task.checkCancellation()
    }

    func recordCompletion(_ completion: ProcessingCompletionStamp, audioURL: URL,
                          fallback: RecordingMetadataPayload) async throws {
        try Task.checkCancellation()
        try await metadataStore.record(completion, audioURL: audioURL, fallback: fallback)
        try Task.checkCancellation()
    }
}
