import Foundation

/// Optional recording scope. Connection tests and other non-recording calls
/// have no context and create no receipt. Tokens retain their originating
/// context, so completion cannot accidentally attach to a newer recording.
enum PrivacyTrace {
    /// The Phase 7 execution audit covers app-managed recording stages. This
    /// never backfills historical evidence or clears persisted gap markers.
    static let coversAllProcessingStages = true
    struct Context: Sendable {
        let receiptURL: URL
        let store: PrivacyReceiptStore
        let runID: UUID
        let recordingID: UUID?

        init(receiptURL: URL, store: PrivacyReceiptStore = .shared, runID: UUID = UUID(), recordingID: UUID? = nil) {
            self.receiptURL = receiptURL
            self.store = store
            self.runID = runID
            self.recordingID = recordingID
        }
    }
    struct Token: Sendable {
        let id: UUID
        let context: Context
    }

    /// Bridges callback APIs that may report a terminal result after cancellation.
    /// Carry the originating token and preserve the first terminal observation.
    final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private let persist: @Sendable (PrivacyAttempt.Outcome) async -> Void
        private var persistenceTask: Task<Void, Never>?

        init(persist: @escaping @Sendable (PrivacyAttempt.Outcome) async -> Void) {
            self.persist = persist
        }
        convenience init(token: Token?) {
            self.init { outcome in await PrivacyTrace.finish(token, outcome: outcome) }
        }

        /// Reserve synchronously at the callback boundary. Scheduling a Task
        /// before reserving would let later cancellation overtake a final result.
        @discardableResult
        func record(_ outcome: PrivacyAttempt.Outcome) -> Task<Void, Never> {
            lock.withLock {
                if let persistenceTask { return persistenceTask }
                let task = Task { [persist] in await persist(outcome) }
                persistenceTask = task
                return task
            }
        }

        func finish(_ outcome: PrivacyAttempt.Outcome) async {
            await record(outcome).value
        }
    }

    @TaskLocal static var context: Context?

    /// Wrap the invocation itself, after caller-side preparation and validation.
    /// Inherit isolation so callers can safely use actor-owned services. Receipt
    /// writes are best effort; operation errors retain their original type.
    static func perform<T>(
        _ operation: PrivacyOperation,
        isolation: isolated (any Actor)? = #isolation,
        body: () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let token = await begin(operation)
        do {
            // Beginning evidence suspends for storage. Cancellation during that
            // suspension must not start the operation when it resumes.
            try Task.checkCancellation()
            let result = try await body()
            await finish(token, outcome: .succeeded)
            return result
        } catch {
            await finish(token, outcome: outcome(for: error))
            throw error
        }
    }

    /// A stream succeeds only after its producer reaches the end. Terminating
    /// the consumer cancels the producer task and therefore its upstream stream.
    static func stream(
        _ operation: PrivacyOperation,
        makeStream: @escaping @Sendable () async throws -> AsyncThrowingStream<String, Error>
    ) -> AsyncThrowingStream<String, Error> {
        let originatingContext = context
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await $context.withValue(originatingContext) {
                        try await perform(operation) {
                            let upstream = try await makeStream()
                            for try await chunk in upstream {
                                try Task.checkCancellation()
                                continuation.yield(chunk)
                            }
                            // AsyncThrowingStream can end iteration normally on
                            // cancellation; that is not a successful completion.
                            try Task.checkCancellation()
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    static func outcome(for error: Error) -> PrivacyAttempt.Outcome {
        error is CancellationError || (error as? URLError)?.code == .cancelled ? .cancelled : .failed
    }

    static func begin(_ operation: PrivacyOperation) async -> Token? {
        await begin(operation, in: context)
    }

    /// Delegate callbacks do not inherit task-local values. They carry their
    /// originating scope explicitly instead of consulting whichever task runs.
    static func begin(_ operation: PrivacyOperation, in context: Context?) async -> Token? {
        guard let context else { return nil }
        do {
            guard let id = try await context.store.begin(operation, runID: context.runID, at: context.receiptURL) else { return nil }
            return Token(id: id, context: context)
        } catch {
            // Never store the error: filesystem/network errors may contain
            // private paths, tokens or provider response content.
            await context.store.noteGap(at: context.receiptURL)
            return nil
        }
    }

    static func finish(_ token: Token?, outcome: PrivacyAttempt.Outcome) async {
        guard let token else { return }
        do {
            try await token.context.store.finish(token.id, outcome: outcome, at: token.context.receiptURL)
        } catch {
            await token.context.store.noteGap(at: token.context.receiptURL)
        }
    }
}
