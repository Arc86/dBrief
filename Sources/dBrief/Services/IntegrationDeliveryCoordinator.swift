import Foundation

/// The send closure is invoked only after its in-flight marker is verified.
/// A crash/timeout after that point requires explicit duplicate-risk confirmation.
actor IntegrationDeliveryCoordinator {
    private let store: any IntegrationDeliveryPersistence
    private var active = Set<UUID>()
    init(store: any IntegrationDeliveryPersistence) { self.store = store }

    func run(
        id: UUID,
        configurationDigests: [IntegrationDestination: String],
        destinations: Set<IntegrationDestination>? = nil,
        allowUncertainRetry: Bool = false,
        acceptConfigurationChange: Bool = false,
        send: @Sendable (IntegrationDeliveryBatch, IntegrationDeliveryBatch.Delivery) async -> IntegrationDispatchResult
    ) async throws -> IntegrationDeliveryBatch {
        guard active.insert(id).inserted else { throw IntegrationDeliveryStore.StoreError.busy }
        defer { active.remove(id) }
        guard var batch = try await store.load(id: id) else {
            throw IntegrationDeliveryStore.StoreError.invalidRecord
        }
        try batch.validate()
        for index in batch.deliveries.indices {
            try Task.checkCancellation()
            let entry = batch.deliveries[index]
            guard !entry.isComplete,
                  destinations == nil || destinations!.contains(entry.destination),
                  !entry.needsDuplicateConfirmation || allowUncertainRetry else { continue }
            if acceptConfigurationChange, let current = configurationDigests[entry.destination] {
                batch.deliveries[index].configurationDigest = current
            }
            guard configurationDigests[entry.destination] == batch.deliveries[index].configurationDigest else {
                // Do not erase uncertainty when settings have also changed.
                if !entry.needsDuplicateConfirmation { batch.deliveries[index].status = .blocked }
                try await store.save(batch)
                continue
            }
            batch.deliveries[index].status = .inFlight
            batch.deliveries[index].attempts += 1
            batch.deliveries[index].updatedAt = Date()
            try await store.save(batch)
            try Task.checkCancellation()
            let result = await send(batch, batch.deliveries[index])
            guard result.destination == entry.destination else {
                throw IntegrationDeliveryStore.StoreError.invalidRecord
            }
            switch result.status {
            case .success: batch.deliveries[index].status = .succeeded
            case .skipped: batch.deliveries[index].status = .skipped
            case .failed: batch.deliveries[index].status = .uncertain
            }
            batch.deliveries[index].remoteID = result.remoteID
            batch.deliveries[index].updatedAt = Date()
            // Even cancellation must not discard a confirmed remote success.
            try await store.save(batch)
        }
        return batch
    }
}
