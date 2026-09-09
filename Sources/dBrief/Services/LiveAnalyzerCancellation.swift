import Foundation

/// Swift task cancellation must invoke the analyzer's native cancellation even
/// while start/finalize is suspended. All error paths join that same cleanup.
final class LiveAnalyzerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelNative: @Sendable () async -> Void
    private var cancellation: Task<Void, Never>?
    private var finished = false

    init(cancel: @escaping @Sendable () async -> Void) { self.cancelNative = cancel }

    func run(_ operation: @Sendable () async throws -> Void) async throws {
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
            } onCancel: {
                self.requestCancellation()
            }
            await finish()
            try Task.checkCancellation()
        } catch {
            requestCancellation()
            await finish()
            throw error
        }
    }

    private func requestCancellation() {
        lock.withLock {
            guard !finished, cancellation == nil else { return }
            let cancel = cancelNative
            cancellation = Task { await cancel() }
        }
    }

    private func finish() async {
        let task = lock.withLock {
            finished = true
            return cancellation
        }
        await task?.value
    }
}
