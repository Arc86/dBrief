import Foundation
import dBriefWire

/// Fan-out for the helper's single per-channel state `AsyncStream`.
///
/// `AsyncStream` is single-consumer: cancelling one `for await` finishes the
/// stream for *everyone*, including future iterations. The proxies vend a fresh
/// subscriber stream per operation (one `for await` per `withPluginStepAdapter`
/// call, cancelled when the op ends), so a single shared stream goes dead after
/// the first op — silently killing live status, live-transcript segments, and
/// download progress on every subsequent transcription in a session.
///
/// A `StateBroadcaster` subscribes to the upstream stream *once* (a long-lived
/// forwarder that is never cancelled) and re-broadcasts each value to any number
/// of independently-cancellable subscriber streams.
final class StateBroadcaster: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var subscribers: [UUID: AsyncStream<LocalAIPluginState>.Continuation] = [:]

    func broadcast(_ value: LocalAIPluginState) {
        lock.lock(); let current = subscribers; lock.unlock()
        for (_, continuation) in current { continuation.yield(value) }
    }

    /// A fresh, independently-cancellable stream of all values broadcast from now on.
    func subscribe() -> AsyncStream<LocalAIPluginState> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock(); subscribers[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.subscribers[id] = nil; self.lock.unlock()
            }
        }
    }

    /// Start the single long-lived forwarder from `upstream`. Never cancelled, so
    /// the upstream stream stays alive for the proxy's whole lifetime.
    func pump(from upstream: @escaping @Sendable () async -> AsyncStream<LocalAIPluginState>) {
        Task { [weak self] in
            for await value in await upstream() {
                guard let self else { return }
                self.broadcast(value)
            }
        }
    }
}
