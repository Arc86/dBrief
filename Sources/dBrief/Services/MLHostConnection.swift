import Foundation
import dBriefWire

enum MLHostError: Error, Equatable {
    case helperCrashed
    case helperUnavailable
    /// A request's terminal `.finished` arrived before any value-bearing event —
    /// the wire ordering invariant was violated (see the `ingestContinuation` and
    /// `StdoutWriter` single-consumer notes). Failing loud beats a leaked
    /// continuation that hangs the caller forever.
    case protocolViolation
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
    // One coder pair for all frames (actor-isolated) — a JSONDecoder/Encoder per
    // frame is measurable overhead on chatty streams (tokens, state events).
    private let frameDecoder = JSONDecoder()
    private let frameEncoder = JSONEncoder()
    // Ordered hand-off of stdout chunks to `ingest`. The readability handler can
    // fire faster than `ingest` runs; feeding a single serial consumer (instead
    // of one Task per chunk) keeps frames — and thus a request's result vs its
    // trailing `.finished` — in order, so replies are never dropped.
    private var ingestContinuation: AsyncStream<Data>.Continuation?

    // Per-request inboxes. A terminal event (result/error/finished) completes the call.
    private struct Pending {
        var onEvent: (MLEvent) -> Void
        var onCrash: () -> Void
        var privacyTrace: PrivacyMLTrace? = nil
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
        let expectsEvidence: Bool = switch request {
        case .transcribe: true
        case .diarize, .diarizeWithEmbeddings: true
        case .parakeetTranscribe(_, _, let diarize): diarize
        default: false
        }
        let trace = expectsEvidence ? PrivacyTrace.context.map { PrivacyMLTrace(context: $0) } : nil
        let progress = MLProgress.sink
        do {
            let id = UUID()
            let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MLEvent, Error>) in
                let resolved = ResolveOnce()
                pending[id] = Pending(
                    onEvent: { event in
                        switch event {
                        case .privacy(let event): trace?.receive(event); return
                        case .state(let state): progress?(state); return
                        case .token: return        // non-terminal for call()
                        // Normally a no-op (the value resolved the call already). If it
                        // resolves here, `.finished` overtook the result frame — fail loud,
                        // because `ingest` drops the pending entry on `.finished` and the
                        // late result could never resume this continuation (permanent hang).
                        case .finished: if resolved.tryResolve() { cont.resume(throwing: MLHostError.protocolViolation) }
                        case .error(let w): if resolved.tryResolve() { cont.resume(throwing: w) }
                        default: if resolved.tryResolve() { cont.resume(returning: event) }
                        }
                    },
                    onCrash: { if resolved.tryResolve() { cont.resume(throwing: MLHostError.helperCrashed) } },
                    privacyTrace: trace
                )
                write(RequestEnvelope(id: id, request: request))
            }
            await trace?.end(crashed: false)
            return result
        } catch {
            await trace?.end(crashed: (error as? MLHostError) == .helperCrashed)
            throw error
        }
    }

    /// Stream tokens for `analyzeStream`/`chatStream`.
    func stream(_ request: MLRequest) -> AsyncThrowingStream<String, Error> {
        let progress = MLProgress.sink
        return AsyncThrowingStream { continuation in
            let id = UUID()
            do { try ensureRunning() } catch {
                continuation.finish(throwing: error); return
            }
            pending[id] = Pending(
                onEvent: { event in
                    switch event {
                    case .state(let state): progress?(state)
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
            guard let env = try? frameDecoder.decode(EventEnvelope.self, from: frame) else {
                // Even an unsupported event may contain a valid request ID. If
                // that too is unreadable, no active receipt can claim completeness.
                struct Header: Decodable { let id: UUID }
                if let header = try? frameDecoder.decode(Header.self, from: frame),
                   let owner = pending[header.id] {
                    owner.privacyTrace?.noteMissingFrame()
                } else {
                    for owner in pending.values { owner.privacyTrace?.noteMissingFrame() }
                }
                continue
            }
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
        guard let stdinHandle, let payload = try? frameEncoder.encode(envelope) else { return }
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
