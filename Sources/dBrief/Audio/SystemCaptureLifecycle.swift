import Foundation

/// Serializes stream creation, startup and teardown. Invalidating an intent is
/// synchronous; completing Stop also waits for stale startup and its cleanup.
@MainActor
final class SystemCaptureLifecycle {
    struct Stream {
        let id: UUID
        let start: @MainActor () async throws -> Void
        let stop: @MainActor () async -> DurabilityDiagnosticFailure?
    }

    private var intent: UUID?
    private var stream: Stream?
    private var tail: Task<Void, Never>?
    private var operationID: UUID?
    private(set) var lastFailure: DurabilityDiagnosticFailure?
    var isBusy: Bool { tail != nil || stream != nil }

    func resetFailure() { lastFailure = nil }

    func accepts(_ id: UUID) -> Bool { intent == id && stream?.id == id }

    func reportFailure(_ failure: DurabilityDiagnosticFailure, from id: UUID) {
        guard accepts(id) else { return }
        lastFailure = failure
    }

    @discardableResult
    func start(
        make: @escaping @MainActor (UUID) async throws -> Stream,
        onFailure: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> Task<Void, Error> {
        let id = UUID(), operation = UUID(), previous = tail
        intent = id
        operationID = operation
        let task = Task { @MainActor in
            await previous?.value
            guard self.intent == id else { return }
            if let old = self.stream {
                self.stream = nil
                await self.close(old)
            }
            guard self.intent == id else { return }
            do {
                let created = try await make(id)
                guard self.intent == id else {
                    await self.close(created)
                    return
                }
                self.stream = created
                do {
                    try await created.start()
                } catch {
                    self.stream = nil
                    await self.close(created)
                    throw error
                }
                if self.intent != id {
                    self.stream = nil
                    await self.close(created)
                }
            } catch {
                // A superseding pause/stop owns the result; a retired startup
                // must not display an error against a newer capture intent.
                guard self.intent == id else { return }
                onFailure(error)
                throw error
            }
        }
        tail = Task { @MainActor in
            _ = await task.result
            self.finish(operation)
        }
        return task
    }

    @discardableResult
    func stop() -> Task<Void, Never> {
        intent = nil
        let operation = UUID(), previous = tail
        operationID = operation
        let task = Task { @MainActor in
            await previous?.value
            if let old = self.stream {
                self.stream = nil
                await self.close(old)
            }
            self.finish(operation)
        }
        tail = task
        return task
    }

    private func close(_ stream: Stream) async {
        if let failure = await stream.stop() { lastFailure = failure }
    }

    private func finish(_ operation: UUID) {
        guard operationID == operation else { return }
        tail = nil
        operationID = nil
    }
}
