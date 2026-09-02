import Darwin
import Foundation

struct ProcessRunResult: Sendable {
    let exitStatus: Int32
    let stdoutTail: Data
    let stderrTail: Data
    let stdoutByteCount: Int64
    let stderrByteCount: Int64
    let elapsedMilliseconds: Int64

    var stdout: String { String(decoding: stdoutTail, as: UTF8.self) }
    var stderr: String { String(decoding: stderrTail, as: UTF8.self) }
}

enum ProcessRunError: Error, LocalizedError, Sendable {
    case launchFailed(domain: String, code: Int)
    case stalled(stderrByteCount: Int64)
    case cancelled(stderrByteCount: Int64)

    var errorDescription: String? {
        switch self {
        case .launchFailed:
            "The audio processor could not be started."
        case .stalled:
            "Audio finalization stopped making progress and was terminated. The original recording tracks were preserved."
        case .cancelled:
            "Audio finalization was cancelled. The original recording tracks were preserved."
        }
    }

    var diagnosticMeasurements: [String: Int64] {
        switch self {
        case .launchFailed(_, let code):
            ["ffmpegLaunchErrorCode": Int64(code)]
        case .stalled(let stderrByteCount):
            ["ffmpegStderrBytes": stderrByteCount, "ffmpegTimedOut": 1]
        case .cancelled(let stderrByteCount):
            ["ffmpegStderrBytes": stderrByteCount, "ffmpegCancelled": 1]
        }
    }
}

/// Runs one child process without allowing either output pipe to fill. Output is
/// continuously consumed, but only a bounded tail is retained. The byte counts
/// remain useful for diagnostics without persisting paths, meeting titles, or
/// other potentially private ffmpeg output.
final class FFmpegProcessRunner: @unchecked Sendable {
    struct Configuration: Sendable {
        var retainedBytesPerPipe = 16 * 1024
        var stallTimeout: TimeInterval = 180
        var watchdogInterval: TimeInterval = 1
        var terminationGracePeriod: TimeInterval = 5
    }

    private let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func run(
        executable: String,
        arguments: [String],
        monitorProgress: Bool,
        stdoutChunkHandler: (@Sendable (Data) -> Void)? = nil
    ) async throws -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = BoundedProcessOutput(limit: configuration.retainedBytesPerPipe)
        let stderrCollector = BoundedProcessOutput(limit: configuration.retainedBytesPerPipe)
        let activity = ProcessActivityClock()
        let execution = ProcessExecution(
            process: process,
            parentWriteHandles: [stdoutPipe.fileHandleForWriting, stderrPipe.fileHandleForWriting],
            terminationGracePeriod: configuration.terminationGracePeriod
        )

        let stdoutDrain = ProcessPipeDrain(handle: stdoutPipe.fileHandleForReading) { data in
                stdoutCollector.append(data)
                activity.markProgress()
                stdoutChunkHandler?(data)
        }
        let stderrDrain = ProcessPipeDrain(handle: stderrPipe.fileHandleForReading) { data in
            stderrCollector.append(data)
        }
        stdoutDrain.start()
        stderrDrain.start()

        let watchdogTask: Task<Void, Never>? = monitorProgress && configuration.stallTimeout > 0
            ? Task.detached { [configuration] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(
                            for: .seconds(max(0.05, configuration.watchdogInterval))
                        )
                    } catch {
                        return
                    }
                    if activity.secondsSinceProgress >= configuration.stallTimeout {
                        execution.requestStop(.stalled)
                        return
                    }
                }
            }
            : nil

        let startedAt = ContinuousClock.now
        do {
            _ = try await withTaskCancellationHandler {
                try await execution.startAndWait()
            } onCancel: {
                execution.requestStop(.cancelled)
            }
        } catch {
            watchdogTask?.cancel()
            stdoutDrain.stop()
            stderrDrain.stop()
            let value = error as NSError
            throw ProcessRunError.launchFailed(domain: value.domain, code: value.code)
        }

        watchdogTask?.cancel()
        await stdoutDrain.waitForEOF()
        await stderrDrain.waitForEOF()

        let elapsed = startedAt.duration(to: .now)
        let elapsedMilliseconds = Int64(
            Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        )

        switch execution.stopReason {
        case .stalled:
            throw ProcessRunError.stalled(stderrByteCount: stderrCollector.totalByteCount)
        case .cancelled:
            throw ProcessRunError.cancelled(stderrByteCount: stderrCollector.totalByteCount)
        case nil:
            break
        }

        return ProcessRunResult(
            exitStatus: process.terminationStatus,
            stdoutTail: stdoutCollector.tail,
            stderrTail: stderrCollector.tail,
            stdoutByteCount: stdoutCollector.totalByteCount,
            stderrByteCount: stderrCollector.totalByteCount,
            elapsedMilliseconds: elapsedMilliseconds
        )
    }

}

/// Installs the read handler before launch and processes bytes directly on the
/// FileHandle delivery queue. This drains the kernel pipe without introducing
/// a second unbounded userspace queue between the child and the bounded tail.
private final class ProcessPipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let onData: @Sendable (Data) -> Void
    private var didFinish = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(handle: FileHandle, onData: @escaping @Sendable (Data) -> Void) {
        self.handle = handle
        self.onData = onData
    }

    func start() {
        handle.readabilityHandler = { [weak self] readableHandle in
            guard let self else { return }
            let data = readableHandle.availableData
            if data.isEmpty {
                self.finish()
            } else {
                self.onData(data)
            }
        }
    }

    func waitForEOF() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                guard !didFinish else { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func stop() {
        finish()
        try? handle.close()
    }

    private func finish() {
        handle.readabilityHandler = nil
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !didFinish else { return [] }
            didFinish = true
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            return pending
        }
        for continuation in pending {
            continuation.resume()
        }
    }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var retained = Data()
    private var byteCount: Int64 = 0

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            byteCount += Int64(data.count)
            guard limit > 0 else {
                retained.removeAll(keepingCapacity: false)
                return
            }
            if data.count >= limit {
                retained = Data(data.suffix(limit))
                return
            }
            let overflow = retained.count + data.count - limit
            if overflow > 0 {
                retained.removeFirst(overflow)
            }
            retained.append(data)
        }
    }

    var totalByteCount: Int64 { lock.withLock { byteCount } }
    var tail: Data { lock.withLock { retained } }
}

private final class ProcessActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var lastProgress = Date()

    func markProgress() {
        lock.withLock { lastProgress = Date() }
    }

    var secondsSinceProgress: TimeInterval {
        lock.withLock { Date().timeIntervalSince(lastProgress) }
    }
}

private final class ProcessExecution: @unchecked Sendable {
    enum StopReason: Sendable {
        case stalled
        case cancelled
    }

    private let lock = NSLock()
    private let process: Process
    private let parentWriteHandles: [FileHandle]
    private let terminationGracePeriod: TimeInterval
    private var requestedStop: StopReason?
    private var launchCompleted = false

    init(
        process: Process,
        parentWriteHandles: [FileHandle],
        terminationGracePeriod: TimeInterval
    ) {
        self.process = process
        self.parentWriteHandles = parentWriteHandles
        self.terminationGracePeriod = terminationGracePeriod
    }

    var stopReason: StopReason? { lock.withLock { requestedStop } }

    func startAndWait() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let resolver = ProcessContinuationResolver(continuation)
            process.terminationHandler = { terminatedProcess in
                resolver.resume(returning: terminatedProcess.terminationStatus)
            }

            if stopReason != nil {
                for handle in parentWriteHandles {
                    try? handle.close()
                }
                resolver.resume(returning: -1)
                return
            }

            do {
                try process.run()
                let stopWasRequested = lock.withLock {
                    launchCompleted = true
                    return requestedStop != nil
                }
                // The child has duplicated these descriptors. Closing the
                // parent's copies guarantees both readers receive EOF at exit.
                for handle in parentWriteHandles {
                    try? handle.close()
                }
                // A cancellation can arrive after the preflight check but
                // before `run()` has made the process visible as running.
                // Re-check once launch completes so that race cannot leave a
                // child behind with nobody waiting for it.
                if stopWasRequested, process.isRunning {
                    process.terminate()
                }
            } catch {
                lock.withLock { launchCompleted = true }
                for handle in parentWriteHandles {
                    try? handle.close()
                }
                resolver.resume(throwing: error)
            }
        }
    }

    func requestStop(_ reason: StopReason) {
        let shouldTerminate = lock.withLock { () -> Bool in
            guard requestedStop == nil else { return false }
            if !launchCompleted {
                requestedStop = reason
                return false
            }
            guard process.isRunning else { return false }
            requestedStop = reason
            return true
        }
        guard shouldTerminate else { return }

        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(0.1, terminationGracePeriod)
        ) { [weak process] in
            guard let process, process.isRunning, process.processIdentifier == pid else { return }
            Darwin.kill(pid, SIGKILL)
        }
    }
}

private final class ProcessContinuationResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Error>?

    init(_ continuation: CheckedContinuation<Int32, Error>) {
        self.continuation = continuation
    }

    func resume(returning status: Int32) {
        let pending = lock.withLock { () -> CheckedContinuation<Int32, Error>? in
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: status)
    }

    func resume(throwing error: Error) {
        let pending = lock.withLock { () -> CheckedContinuation<Int32, Error>? in
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(throwing: error)
    }
}
