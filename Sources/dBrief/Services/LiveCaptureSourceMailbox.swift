import Foundation
import dBriefWire

/// A raw relay and control observer share one bounded source consumer. Audio
/// keeps its original receipt; a wake is only a request to recheck control state.
final class LiveCaptureSourceMailbox: @unchecked Sendable {
    enum Event: Sendable { case audio(LiveAudioBuffer), wake }
    let events: AsyncStream<Event>
    private let output: AsyncStream<Event>.Continuation
    private let ingress: LiveCaptureIngress
    private let source: LiveSource
    private let lock = NSLock()
    private var pending: Set<UUID> = []
    private var wakePending = false
    private var closed = false

    init(ingress: LiveCaptureIngress, source: LiveSource) throws {
        guard ingress.input.isValid, ingress.input.epochs.contains(where: { $0.source == source }) else { throw LiveProtocolError.invalidConfiguration }
        self.ingress = ingress; self.source = source
        (events,output) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(65))
    }

    func offer(_ item: LiveAudioBuffer) -> Bool {
        guard let ticket = item.ingress, ticket.owner === ingress, ticket.source == source else { return false }
        return lock.withLock {
            // Reject aliases without discarding the originally queued receipt.
            guard !pending.contains(ticket.id), ingress.isPendingRaw(ticket) else { return false }
            guard !closed else { ticket.discard(reason: .stopped); return false }
            guard pending.count < 64 else { ticket.discard(reason: .overload); return false }
            pending.insert(ticket.id)
            switch output.yield(.audio(item)) {
            case .enqueued: return true
            case .dropped:
                pending.remove(ticket.id); ticket.discard(reason: .overload); return false
            case .terminated:
                pending.remove(ticket.id); ticket.discard(reason: .stopped); return false
            @unknown default:
                pending.remove(ticket.id); ticket.discard(reason: .unavailable); return false
            }
        }
    }
    func wake() {
        lock.withLock {
            guard !closed, !wakePending else { return }
            wakePending = true
            if case .enqueued = output.yield(.wake) { return }
            wakePending = false
        }
    }
    func consumedWake() { lock.withLock { wakePending = false } }
    /// Called after this consumer's send/disposal, not when merely dequeued.
    func completedAudio(_ id: UUID) { lock.withLock { _ = pending.remove(id) } }
    func finish() { lock.withLock { closed = true; output.finish() } }
}
