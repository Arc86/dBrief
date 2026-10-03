import Foundation

/// Stream termination cancels consumption; this receipt separately joins the
/// actual producer return, including a provider that ignores cancellation.
struct ChatStreamRun: Sendable {
    let stream: AsyncThrowingStream<String, any Error>
    private let cancelProducer: @Sendable () -> Void
    private let joinProducer: @Sendable () async -> Void
    init(stream: AsyncThrowingStream<String, any Error>, producer: Task<Void, Never>) {
        self.stream = stream; cancelProducer = { producer.cancel() }; joinProducer = { await producer.value }
    }
    init(stream: AsyncThrowingStream<String, any Error>, cancel: @escaping @Sendable () -> Void = {},
         join: @escaping @Sendable () async -> Void = {}) {
        self.stream = stream; cancelProducer = cancel; joinProducer = join
    }
    func cancel() { cancelProducer() }
    func waitForReturn() async { await joinProducer() }
}

/// Bounds before producer strings enter an AsyncStream queue. Overflow is an
/// explicit incomplete result; buffering never silently replaces evidence.
final class ChatStreamBuffer: @unchecked Sendable {
    static let textLimit = 256 * 1_024
    static let chunkLimit = 32 * 1_024
    static let lineLimit = 64 * 1_024
    let stream: AsyncThrowingStream<String, any Error>
    let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let bounded: Bool
    private var textBytes = 0 // Exactly one producer per buffer.
    init(bounded: Bool) {
        self.bounded = bounded
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: bounded ? .bufferingOldest(8) : .unbounded)
    }
    func yield(_ text: String) throws {
        guard bounded else { continuation.yield(text); return }
        let bytes = text.utf8.count
        guard bytes <= Self.textLimit - textBytes else { throw ChatStreamEndError.limited }
        textBytes += bytes
        var start = text.startIndex, end = start, count = 0
        for scalar in text.unicodeScalars {
            if scalar.utf8.count > Self.chunkLimit - count {
                try enqueue(String(text[start..<end])); start = end; count = 0
            }
            count += scalar.utf8.count; end = text.unicodeScalars.index(after: end)
        }
        if start != end { try enqueue(String(text[start..<end])) }
    }
    private func enqueue(_ text: String) throws {
        switch continuation.yield(text) {
        case .enqueued: return
        case .dropped: throw ChatStreamEndError.limited
        case .terminated: throw CancellationError()
        @unknown default: throw ChatStreamEndError.unconfirmed
        }
    }
}

/// A single request owns one return waiter. Completion is sticky and is
/// reported by a helper terminal frame or its exact process exit.
final class ChatStreamReturn: @unchecked Sendable {
    private let lock = NSLock()
    private var returned = false
    private var waiter: CheckedContinuation<Void, Never>?
    func finish() {
        let current = lock.withLock {
            returned = true; let current = waiter; waiter = nil; return current
        }
        current?.resume()
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if returned { return true }
                precondition(waiter == nil); waiter = continuation; return false
            }
            if ready { continuation.resume() }
        }
    }
}
