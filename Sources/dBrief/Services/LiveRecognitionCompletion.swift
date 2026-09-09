import Foundation

/// Joins native recognition acknowledgment and its privacy receipt write.
/// Cancellation requests do not stand in for the native terminal callback.
final class LiveRecognitionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let completion: PrivacyTrace.Completion
    private var cancellation: (@Sendable () -> Void)?
    private var cancellationRequested = false
    private var acknowledged = false
    private var settled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(completion: PrivacyTrace.Completion) { self.completion = completion }

    func installCancellation(_ action: @escaping @Sendable () -> Void) {
        let shouldCancel = lock.withLock {
            guard !acknowledged else { return false }
            cancellation = action
            return cancellationRequested
        }
        if shouldCancel { action() }
    }

    func requestCancellation() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !cancellationRequested, !acknowledged else { return nil }
            cancellationRequested = true
            completion.record(.cancelled)
            return cancellation
        }
        action?()
    }

    /// Reserve final output before mapping/publishing it, retaining the existing
    /// first-observed outcome when a later Stop races with that work.
    func observe(_ outcome: PrivacyAttempt.Outcome) { completion.record(outcome) }

    func acknowledge(_ outcome: PrivacyAttempt.Outcome) {
        let persistence = lock.withLock { () -> Task<Void, Never>? in
            guard !acknowledged else { return nil }
            acknowledged = true
            cancellation = nil
            return completion.record(outcome)
        }
        guard let persistence else { return }
        Task {
            await persistence.value
            let continuations = self.lock.withLock {
                self.settled = true
                let waiting = self.waiters
                self.waiters = []
                return waiting
            }
            continuations.forEach { $0.resume() }
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let finished = lock.withLock {
                if settled { return true }
                waiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
    }
}
