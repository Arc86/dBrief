import Foundation

/// Serializes GPU-resident model access so concurrent transcription/analysis
/// never allocate competing CoreML/Metal buffers in the helper process.
actor AsyncMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pendingCleanup: Task<Void, Never>?

    func withLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await lock()
        defer { unlock() }
        try Task.checkCancellation()
        return try await operation()
    }

    /// One cleanup per burst of warnings, using the same lock as inference.
    /// The owned task is intentionally independent of the requesting task's
    /// cancellation: once scheduled, cleanup must run after inference unwinds.
    func enqueueCleanup(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        if let pendingCleanup { return pendingCleanup }
        let task = Task {
            try? await withLock { await operation() }
            pendingCleanup = nil
        }
        pendingCleanup = task
        return task
    }

    private func lock() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func unlock() {
        if waiters.isEmpty {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}
