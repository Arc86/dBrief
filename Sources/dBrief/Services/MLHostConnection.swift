import Foundation
import dBriefWire

enum MLHostError: Error, Equatable {
    case helperCrashed
    case helperUnavailable
}

/// Owns the child helper process, frames IO over its pipes, correlates replies
/// by request id, demultiplexes per-channel state, and relaunches on crash.
actor MLHostConnection {
    private let binaryURL: URL
    private let supportBase: URL
    private let extraEnvironment: [String: String]

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var reader = FrameReader()
    // Ordered hand-off of stdout chunks to `ingest`. The readability handler can
    // fire faster than `ingest` runs; feeding a single serial consumer (instead
    // of one Task per chunk) keeps frames — and thus a request's result vs its
    // trailing `.finished` — in order, so replies are never dropped.
    private var ingestContinuation: AsyncStream<Data>.Continuation?

    // Per-request inboxes. A terminal event (result/error/finished) completes the call.
    private struct Pending {
        var onEvent: (MLEvent) -> Void
        var onCrash: () -> Void
    }
    private var pending: [UUID: Pending] = [:]

    // Per-channel state stream continuations (vended to the proxies).
    private var stateContinuations: [MLChannel: AsyncStream<LocalAIPluginState>.Continuation] = [:]

    init(binaryURL: URL, supportBase: URL, environment: [String: String] = [:]) {
        self.binaryURL = binaryURL
        self.supportBase = supportBase
        self.extraEnvironment = environment
    }

    // MARK: state streams

    func stateStream(for channel: MLChannel) -> AsyncStream<LocalAIPluginState> {
        AsyncStream { continuation in
            stateContinuations[channel] = continuation
        }
    }

    // MARK: request/response

    /// Send a request and await its terminal event (`.error` throws the `WireError`,
    /// a process death throws `MLHostError.helperCrashed`).
    func call(_ request: MLRequest) async throws -> MLEvent {
        try ensureRunning()
        let id = UUID()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MLEvent, Error>) in
            let resolved = ResolveOnce()
            pending[id] = Pending(
                onEvent: { event in
                    switch event {
                    case .state, .token: return        // non-terminal for call()
                    case .finished: return             // terminal handled after a value
                    case .error(let w): if resolved.tryResolve() { cont.resume(throwing: w) }
                    default: if resolved.tryResolve() { cont.resume(returning: event) }
                    }
                },
                onCrash: { if resolved.tryResolve() { cont.resume(throwing: MLHostError.helperCrashed) } }
            )
            write(RequestEnvelope(id: id, request: request))
        }
    }

    /// Stream tokens for `analyzeStream`/`chatStream`.
    func stream(_ request: MLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            do { try ensureRunning() } catch {
                continuation.finish(throwing: error); return
            }
            pending[id] = Pending(
                onEvent: { event in
                    switch event {
                    case .token(let s): continuation.yield(s)
                    case .finished: continuation.finish()
                    case .error(let w): continuation.finish(throwing: w)
                    default: break
                    }
                },
                onCrash: { continuation.finish(throwing: MLHostError.helperCrashed) }
            )
            continuation.onTermination = { @Sendable _ in
                Task { await self.send(.cancel, id: id) }
            }
            write(RequestEnvelope(id: id, request: request))
        }
    }

    func shutdown() {
        process?.terminate()
        process = nil
        stdinHandle = nil
        ingestContinuation?.finish()
        ingestContinuation = nil
    }

    // MARK: process lifecycle

    private func ensureRunning() throws {
        if process?.isRunning == true { return }
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["--support-base", supportBase.path]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnvironment { env[k] = v }
        proc.environment = env

        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // stderr inherited so the helper's OSLog/stderr surfaces.

        // Serial consumer: chunks are ingested strictly in arrival order.
        ingestContinuation?.finish()
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.ingestContinuation = continuation
        Task { [weak self] in
            for await data in stream { await self?.ingest(data) }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [continuation] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            continuation.yield(data)
        }
        proc.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }
        do {
            try proc.run()
        } catch {
            throw MLHostError.helperUnavailable
        }
        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.reader = FrameReader()
    }

    private func send(_ request: MLRequest, id: UUID) {
        write(RequestEnvelope(id: id, request: request))
    }

    private func ingest(_ data: Data) {
        reader.append(data)
        for frame in reader.drainFrames() {
            guard let env = try? JSONDecoder().decode(EventEnvelope.self, from: frame) else { continue }
            if case let .state(state) = env.event {
                stateContinuations[env.channel]?.yield(state)
            }
            if let p = pending[env.id] {
                p.onEvent(env.event)
                switch env.event {
                case .finished, .error: pending[env.id] = nil
                default: break
                }
            }
        }
    }

    private func handleTermination() {
        let dead = pending
        pending.removeAll()
        process = nil
        stdinHandle = nil
        for (_, p) in dead { p.onCrash() }
    }

    private func write(_ envelope: RequestEnvelope) {
        guard let stdinHandle, let payload = try? JSONEncoder().encode(envelope) else { return }
        stdinHandle.write(FrameCodec.encode(payload))
    }
}

/// Guards a continuation against double-resume across the event/crash closures.
private final class ResolveOnce: @unchecked Sendable {
    private var done = false
    func tryResolve() -> Bool {
        if done { return false }
        done = true
        return true
    }
}
