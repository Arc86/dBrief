import Foundation

/// Recovery and processing share the same writer as descriptive metadata edits.
/// Keep reconciliation as an explicit durability boundary before journal removal.
enum RecordingCompletionStore {
    typealias Failure = RecordingMetadataStore.Failure

    static func record(_ completion: ProcessingCompletionStamp, audioURL: URL,
                       fallback: RecordingMetadataPayload) async throws {
        try await RecordingMetadataStore.shared.record(completion, audioURL: audioURL, fallback: fallback)
    }

    static func reconcile(_ record: PersistedProcessingJob) async throws {
        try await RecordingMetadataStore.shared.reconcile(record)
    }

    static func reconcile(_ batch: IntegrationDeliveryBatch) async throws {
        try await RecordingMetadataStore.shared.reconcile(batch)
    }
}
