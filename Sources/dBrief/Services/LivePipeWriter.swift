import Darwin
import Foundation

/// One blocking writer outside the connection actor. The byte bound includes the
/// frame currently blocked in the kernel, so a child that stops reading cannot
/// grow an unbounded backlog or prevent the actor's force deadline from firing.
final class LivePipeWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private let writeLock = NSLock()
    private let queue = DispatchQueue(label: "dBrief.live-helper-input")
    private let failed: @Sendable () -> Void
    private let testingMandatoryWrite: @Sendable (Bool) -> Void
    private var frames: [Data] = []
    private var bytes = 0
    private var draining = false
    private var retired = false
    private var frameCount = 0

    init(handle: FileHandle, testingMandatoryWrite: @escaping @Sendable (Bool) -> Void = { _ in }, failed: @escaping @Sendable () -> Void) {
        self.handle = handle; self.failed = failed; self.testingMandatoryWrite = testingMandatoryWrite
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

    /// No queue or blocking descriptor write for optional work. Mandatory work
    /// owns priority, including a frame already removed from the queue.
    func tryWriteOptional(_ frame: Data) -> Bool {
        guard !frame.isEmpty, frame.count <= 512, writeLock.try() else { return false }
        defer { writeLock.unlock() }
        guard lock.try() else { return false }
        let idle = !retired && !draining && frames.isEmpty && frameCount == 0
        lock.unlock()
        guard idle else { return false }
        let fd = handle.fileDescriptor; var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
              frame.count <= fpathconf(fd, _PC_PIPE_BUF) else { return false }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        for _ in 0..<3 {
            let n = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n == frame.count { return true }
            if n < 0, errno == EINTR { continue }
            return false // Atomic <=PIPE_BUF nonblocking FIFO writes are all-or-none.
        }
        return false
    }

    /// Call after killing the owning child, which releases any blocked write.
    func retire() {
        lock.withLock { retired = true; frames.removeAll() }
        queue.async { self.writeLock.withLock { try? self.handle.close() } }
    }

    private func drain() {
        while true {
            let frame: Data? = lock.withLock {
                guard !retired, !frames.isEmpty else { draining = false; return nil }
                return frames.removeFirst()
            }
            guard let frame else { return }
            do { try writeLock.withLock {
                testingMandatoryWrite(true); defer { testingMandatoryWrite(false) }
                try handle.write(contentsOf: frame)
            } }
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
