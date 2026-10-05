import Darwin
import Foundation

/// One serial writer outside the connection actor. Queued bytes include the
/// frame currently in the kernel. Owned ordinary input uses bounded nonblocking
/// effects so source retirement never waits behind a full FIFO.
final class LivePipeWriter: @unchecked Sendable {
    static let maximumQueuedBytes = 512 * 1_024
    private struct Frame {
        let data: Data
        let ownership: TranscriptContextOwnership?
        let returned: ChatStreamReturn?
    }
    private let handle: FileHandle
    private let lock = NSLock()
    private let writeLock = NSLock()
    private let queue = DispatchQueue(label: "dBrief.live-helper-input")
    private let failed: @Sendable () -> Void
    private let testingMandatoryWrite: @Sendable (Bool) -> Void
    private let nonblockingWrites: Bool
    let isReady: Bool
    private var frames: [Frame] = []
    private var bytes = 0
    private var draining = false
    private var retired = false
    private var frameCount = 0
    private var retirement: Task<Void, Never>?
    var residentBytes: Int { lock.withLock { bytes } }

    init(handle: FileHandle, nonblockingWrites: Bool = false,
         testingMandatoryWrite: @escaping @Sendable (Bool) -> Void = { _ in }, failed: @escaping @Sendable () -> Void) {
        self.handle = handle; self.failed = failed; self.testingMandatoryWrite = testingMandatoryWrite
        self.nonblockingWrites = nonblockingWrites
        let fd = handle.fileDescriptor, noSignal = fcntl(fd, F_SETNOSIGPIPE, 1)
        if nonblockingWrites {
            var info = stat(); let flags = fcntl(fd, F_GETFL)
            isReady = noSignal == 0 && fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO &&
                flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
        } else { isReady = true }
    }

    func enqueue(_ frame: Data, ownership: TranscriptContextOwnership? = nil, returned: ChatStreamReturn? = nil) -> Bool {
        lock.withLock {
            guard isReady, !retired, (nonblockingWrites || ownership == nil), frameCount < 128,
                  frame.count <= Self.maximumQueuedBytes - bytes else { return false }
            frames.append(.init(data: frame, ownership: ownership, returned: returned))
            bytes += frame.count; frameCount += 1
            if !draining { draining = true; queue.async { self.drain() } }
            return true
        }
    }

    /// No queue or blocking descriptor write for optional live work. Mandatory
    /// work owns priority, including a frame already removed from the queue.
    func tryWriteOptional(_ frame: Data) -> Bool {
        guard !nonblockingWrites, !frame.isEmpty, frame.count <= 512, writeLock.try() else { return false }
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
            return false
        }
        return false
    }

    /// Live blocking writers require their owning child to be killed first.
    /// Owned nonblocking writers observe this latch without waiting for stdin.
    /// Every caller shares the actual serial close receipt, even after failure.
    @discardableResult func retire() -> Task<Void, Never> {
        lock.withLock {
            if let retirement { return retirement }
            retired = true; discardQueued()
            let returned = ChatStreamReturn(), task = Task { await returned.wait() }
            retirement = task
            queue.async {
                self.writeLock.withLock { try? self.handle.close() }
                returned.finish()
            }
            return task
        }
    }

    /// Called only while holding the state lock. In-flight frames stay owned.
    private func discardQueued() {
        for frame in frames { bytes -= frame.data.count; frameCount -= 1; frame.returned?.finish() }
        frames.removeAll()
    }

    private func drain() {
        while true {
            let frame: Frame? = lock.withLock {
                guard !retired, !frames.isEmpty else { draining = false; return nil }
                return frames.removeFirst()
            }
            guard let frame else { return }
            defer { withExtendedLifetime(frame.ownership) {} }
            do {
                if nonblockingWrites {
                    testingMandatoryWrite(true)
                    do { defer { testingMandatoryWrite(false) }; try writeNonblocking(frame) }
                } else {
                    try writeLock.withLock {
                        testingMandatoryWrite(true); defer { testingMandatoryWrite(false) }
                        try handle.write(contentsOf: frame.data)
                    }
                }
            } catch {
                let notify = lock.withLock {
                    let active = !retired; retired = true; discardQueued()
                    bytes -= frame.data.count; frameCount -= 1; draining = false
                    return active
                }
                frame.returned?.finish()
                if notify { failed() }
                _ = retire()
                return
            }
            lock.withLock { bytes -= frame.data.count; frameCount -= 1 }
            frame.returned?.finish()
        }
    }

    private func writeNonblocking(_ frame: Frame) throws {
        let fd = handle.fileDescriptor, atomicLimit = fpathconf(fd, _PC_PIPE_BUF)
        guard atomicLimit > 0 else { throw MLHostError.helperCrashed }
        var offset = 0
        while offset < frame.data.count {
            let count = min(Int(atomicLimit), frame.data.count - offset)
            let result: (count: Int, error: Int32) = try TranscriptContextOwnership.withValidResult(frame.ownership) {
                try lock.withLock {
                    guard !retired else { throw CancellationError() }
                    let n = frame.data.withUnsafeBytes {
                        Darwin.write(fd, $0.baseAddress!.advanced(by: offset), count)
                    }
                    return (n, n < 0 ? errno : 0)
                }
            }
            if result.count == count { offset += count; continue }
            if result.count >= 0 { throw MLHostError.helperCrashed } // Atomic FIFO write anomaly.
            if result.error == EINTR { continue }
            guard result.error == EAGAIN || result.error == EWOULDBLOCK else { throw MLHostError.helperCrashed }
            guard !lock.withLock({ retired }) else { throw CancellationError() }
            try TranscriptContextOwnership.requireValid(frame.ownership)
            // No source/state/descriptor lock is held while the FIFO is full.
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, 20)
            if ready < 0 { if errno == EINTR { continue }; throw MLHostError.helperCrashed }
            guard descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { throw MLHostError.helperCrashed }
        }
    }
}

/// At most one overflow notification crosses from a pipe callback to the actor.
final class LiveReadFailureLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    func claim() -> Bool { lock.withLock { if failed { return false }; failed = true; return true } }
}
