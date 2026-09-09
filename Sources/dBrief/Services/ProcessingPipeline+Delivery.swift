import Foundation

extension ProcessingPipeline {
    struct DeliveryPreparation: Sendable {
        let jobID: UUID
        let recording: RecordingSnapshot
        let configuration: IntegrationSettings
        let markdownURL: URL?
        let requireTranscript: Bool
        let processingSucceededBeforeDeliveryAt: Date?
    }
    struct DeliveryRun: Sendable {
        let id: UUID
        let configurationDigests: [IntegrationDestination: String]
        var destinations: Set<IntegrationDestination>? = nil
        var allowUncertainRetry = false
        var acceptConfigurationChange = false
    }
    enum DeliveryEvent: Sendable {
        case started(IntegrationDeliveryBatch.Delivery)
        case finished(IntegrationDispatchResult)
    }
    struct DeliveryHandoff: Sendable {
        let batch: IntegrationDeliveryBatch
        let held: Bool
        let completion: ProcessingCompletionStamp?
    }

    func prepareDeliveries(_ request: DeliveryPreparation, store: IntegrationDeliveryStore,
                           service: IntegrationDispatchService,
                           validateOwnership: @Sendable () async throws -> Void = {}) async throws -> IntegrationDeliveryBatch {
        try Task.checkCancellation()
        try await validateOwnership()
        try Task.checkCancellation()
        if let existing = try await store.load(id: request.jobID) {
            try Task.checkCancellation()
            try await validateOwnership()
            try Task.checkCancellation()
            return existing
        }
        try Task.checkCancellation()
        try await validateOwnership()
        try Task.checkCancellation()
        var proposed = try await service.prepareBatch(jobID: request.jobID, recording: request.recording,
            config: request.configuration, generatedMarkdownURL: request.markdownURL, requireTranscript: request.requireTranscript)
        try Task.checkCancellation()
        try await validateOwnership()
        try Task.checkCancellation()
        proposed.processingSucceededBeforeDeliveryAt = request.processingSucceededBeforeDeliveryAt
        let saved = try await store.createIfAbsent(proposed)
        try Task.checkCancellation()
        try await validateOwnership()
        try Task.checkCancellation()
        return saved
    }

    func runDeliveries(_ request: DeliveryRun, coordinator: IntegrationDeliveryCoordinator,
                       send: @Sendable (IntegrationDeliveryBatch, IntegrationDeliveryBatch.Delivery) async -> IntegrationDispatchResult,
                       onEvent: @Sendable (DeliveryEvent) async -> Void = { _ in },
                       validateOwnership: @Sendable () async throws -> Void = {}) async throws -> IntegrationDeliveryBatch {
        try Task.checkCancellation()
        try await validateOwnership()
        try Task.checkCancellation()
        let result = try await coordinator.run(id: request.id, configurationDigests: request.configurationDigests,
            destinations: request.destinations, allowUncertainRetry: request.allowUncertainRetry,
            acceptConfigurationChange: request.acceptConfigurationChange, validateOwnership: validateOwnership) { saved, entry in
                await onEvent(.started(entry))
                // The in-flight marker already exists. If ownership/cancellation
                // changes during the UI hop, leave conservative retry evidence.
                do {
                    try Task.checkCancellation()
                    try await validateOwnership()
                    try Task.checkCancellation()
                } catch {
                    return .init(destination: entry.destination, status: .failed, message: "Delivery stopped before sending", remoteID: nil)
                }
                let outcome = await send(saved, entry)
                await onEvent(.finished(outcome))
                // Never throw after send: the coordinator must persist confirmed
                // outcomes even if the task was cancelled while awaiting them.
                return outcome
            }
        try Task.checkCancellation()
        try await validateOwnership()
        try Task.checkCancellation()
        return result
    }

    /// Intent is frozen by prepareDeliveries before entering this boundary. A
    /// held recovery parks locally; a normal run acknowledges completion only
    /// after every delivery and the processing checkpoint have succeeded.
    func finishDeliveryHandoff(_ batch: IntegrationDeliveryBatch, stopBeforeIntegrations: Bool,
                               run: @Sendable (IntegrationDeliveryBatch) async throws -> IntegrationDeliveryBatch,
                               park: @Sendable () async throws -> Void,
                               checkpoint: @Sendable () async throws -> Void,
                               validateOwnership: @Sendable () async throws -> Void = {}) async throws -> DeliveryHandoff {
        try Task.checkCancellation()
        try await validateOwnership()
        try Task.checkCancellation()
        if stopBeforeIntegrations {
            try await park()
            try Task.checkCancellation()
            try await validateOwnership()
            try Task.checkCancellation()
            return .init(batch: batch, held: true, completion: nil)
        }
        let result = try await run(batch)
        try Task.checkCancellation()
        try await validateOwnership()
        try Task.checkCancellation()
        guard result.isComplete else { return .init(batch: result, held: false, completion: nil) }
        try await checkpoint()
        try Task.checkCancellation()
        try await validateOwnership()
        try Task.checkCancellation()
        return .init(batch: result, held: false, completion: result.successfulWorkflowCompletion)
    }
}
