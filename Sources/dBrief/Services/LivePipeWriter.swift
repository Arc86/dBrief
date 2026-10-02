import Darwin
import Foundation

/// One blocking writer outside the connection actor. The byte bound includes the
/// frame currently blocked in the kernel, so a child that stops reading cannot
/// grow an unbounded backlog or prevent the actor's force deadline from firing.
final class LivePipeWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dBrief.live-helper-input")
    private let failed: @Sendable () -> Void
    private var frames: [Data] = []
    private var bytes = 0
    private var draining = false
    private var retired = false
    private var frameCount = 0

    init(handle: FileHandle, failed: @escaping @Sendable () -> Void) {
        self.handle = handle; self.failed = failed
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func enqueue(_ frame: Data) -> Bool {
        let accepted = lock.withLock {
            guard !retired, frameCount < 128, frame.count <= 524288 - bytes else { return false }
            frames.append(frame); bytes += frame.count; frameCount += 1
            if !draining { draining = true; queue.async { self.drain() } }
            return true
        }
        return accepted
    }

    /// Call after killing the owning child, which releases any blocked write.
    func retire() {
        lock.withLock { retired = true; frames.removeAll() }
        queue.async { try? self.handle.close() }
    }

    private func drain() {
        while true {
            let frame: Data? = lock.withLock {
                guard !retired, !frames.isEmpty else { draining = false; return nil }
                return frames.removeFirst()
            }
            guard let frame else { return }
            do { try handle.write(contentsOf: frame) }
            catch {
                let notify = lock.withLock { let active = !retired; retired = true; frames.removeAll(); return active }
                if notify { failed() }
                return
            }
            lock.withLock { bytes -= frame.count; frameCount -= 1 }
        }
    }
}

/// At most one overflow notification crosses from a pipe callback to the actor.
final class LiveReadFailureLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    func claim() -> Bool { lock.withLock { if failed { return false }; failed = true; return true } }
}
