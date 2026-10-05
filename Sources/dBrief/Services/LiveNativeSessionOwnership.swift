import Foundation
import dBriefWire

/// Accepted native work has a lifetime independent of weak event/timer callbacks.
/// The shutdown task captures payload values, never this token or its core.
final class LiveNativeSessionOwnership: @unchecked Sendable {
    private final class BeginLifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var returned = false
        private var waiter: CheckedContinuation<Void,Never>?
        var hasReturned: Bool { lock.withLock { returned } }
        func finish() {
            let original = lock.withLock { returned = true; let original = waiter; waiter = nil; return original }
            original?.resume()
        }
        func wait() async {
            await withCheckedContinuation { continuation in
                let done = lock.withLock {
                    if returned { return true }; waiter = continuation; return false
                }
                if done { continuation.resume() }
            }
        }
    }
    private struct Payload: Sendable {
        let owner: UUID
        let input: LiveSessionBegin
        let transport: LiveASRTransport
        let ingress: LiveCaptureIngress?
        let resources: LiveModelResourcePolicy?
        let lease: LiveResourceLease?
        let preparation: LiveCaptureStartPreparation?
        let store: LiveTranscriptStore
    }
    private let payload: Payload
    private let lock = NSLock()
    private let beginLifetime = BeginLifetime()
    private var shutdownTask: Task<Void,Never>?
    init(owner: UUID, input: LiveSessionBegin, transport: LiveASRTransport, ingress: LiveCaptureIngress?,
         resources: LiveModelResourcePolicy?, lease: LiveResourceLease?, preparation: LiveCaptureStartPreparation?, store: LiveTranscriptStore) {
        payload = .init(owner: owner,input: input,transport: transport,ingress: ingress,resources: resources,lease: lease,preparation: preparation,store: store)
    }
    deinit { _ = shutdown(ownerLost: true) }
    func beginReturned() { beginLifetime.finish() }
    @discardableResult func shutdown(ownerLost: Bool = false) -> Task<Void,Never> {
        lock.withLock {
            if let shutdownTask { return shutdownTask }
            let original = payload
            let beginLifetime = self.beginLifetime, pendingBegin = !beginLifetime.hasReturned
            if ownerLost {
                original.preparation?.complete(.failed,owner: original.owner)
                original.ingress?.retireInput()
                let losses = original.input.epochs.flatMap { original.ingress?.takeLosses($0.source) ?? [] }
                Task { await original.store.abandonCaptureOwner(original.owner,losses: losses) }
            }
            let work = Task {
                await original.transport.shutdown()
                if pendingBegin {
                    // A cancellation-ignoring transport may create/return late
                    // work after its first shutdown. Actual Begin return plus
                    // subsequent teardown precede asset/lease/credit release.
                    await beginLifetime.wait()
                    await original.transport.shutdown()
                }
                original.ingress?.confirmNativeRetired(owner: original.owner)
                await original.preparation?.attribution?.joinAfterExit()
                await original.preparation?.retireNativeAssets(owner: original.owner)?.value
                if let resources = original.resources, let lease = original.lease { await resources.release(lease) }
            }
            shutdownTask = work; return work
        }
    }
}
