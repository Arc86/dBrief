import Darwin
import Foundation
import dBriefWire

enum MLHostError: Error, Equatable, LocalizedError {
    case helperCrashed
    case helperUnavailable
    /// A request's terminal `.finished` arrived before any value-bearing event —
    /// the wire ordering invariant was violated (see the `ingestContinuation` and
    /// `StdoutWriter` single-consumer notes). Failing loud beats a leaked
    /// continuation that hangs the caller forever.
    case protocolViolation
    case liveDeadline
    case resourceDeferred
    var errorDescription: String? {
        switch self {
        case .resourceDeferred: "Local chat is waiting for live transcription to free memory. Try again after recording stops."
        case .helperCrashed: "The local AI helper stopped unexpectedly."
        case .helperUnavailable: "The local AI helper is unavailable."
        case .protocolViolation: "The local AI helper returned an invalid response."
        case .liveDeadline: "Live transcription did not finish before its deadline."
        }
    }
}

enum MLHostRole: Sendable { case ordinary, live }

/// Owns the child helper process, frames IO over its pipes, correlates replies
/// by request id, demultiplexes per-channel state, and relaunches on crash.
actor MLHostConnection {
    struct LiveEventLimits: Sendable {
        var queued = 512
        var deferred: Int? = nil
        var accountedBytes: Int? = nil
        static let recording = Self(queued: 8, deferred: 8, accountedBytes: 256 * 1_024)
    }
    private let liveEventLimits: LiveEventLimits
    private let binaryURL: URL
    private let supportBase: URL
    private let extraEnvironment: [String: String]
    private let role: MLHostRole
    private let terminationDelivery: @Sendable () async -> Void
    private let retirementWaitDelivery: (@Sendable () async -> Void)?
    nonisolated let resourceAdmission: LiveModelJobAdmission?
    private var ordinaryGeneration = UUID()
    private var nativeJobs: [UUID:MLNativeJobOwnership] = [:]
    private var activeNativeJobs: Set<UUID> = []
    private var ordinaryRetirement: Task<Void,Never>?

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
        var onCrash: (Error) -> Void
        var privacyTrace: PrivacyMLTrace? = nil
        var liveRequest: LiveSessionRequest? = nil
        var liveReplied = false
        var liveCompletionSeen = false
    }
    private var pending: [UUID: Pending] = [:]

    // Per-channel state stream continuations (vended to the proxies).
    private var stateContinuations: [MLChannel: AsyncStream<LocalAIPluginState>.Continuation] = [:]

    init(binaryURL: URL, supportBase: URL, environment: [String: String] = [:], role: MLHostRole = .ordinary,
         resourceAdmission: LiveModelJobAdmission? = nil, terminationDelivery: @escaping @Sendable () async -> Void = {},
         retirementWaitDelivery: (@Sendable () async -> Void)? = nil, liveEventLimits: LiveEventLimits = .init()) {
        self.binaryURL = binaryURL
        self.supportBase = supportBase
        self.extraEnvironment = environment
        self.role = role; self.resourceAdmission = role == .ordinary ? resourceAdmission : nil
        self.terminationDelivery = terminationDelivery
        self.retirementWaitDelivery = retirementWaitDelivery
        self.liveEventLimits = .init(queued: min(512, max(1, liveEventLimits.queued)),
            deferred: liveEventLimits.deferred.map { min(32, max(1, $0)) },
            accountedBytes: liveEventLimits.accountedBytes.map { min(512 * 1_024, max(1, $0)) })
    }

    private var liveReader = LiveFrameReader()
    private var liveWriter: LivePipeWriter?
    private var liveStream: AsyncThrowingStream<LiveSessionEvent, Error>.Continuation?
    private var liveBegin: LiveSessionBegin?
    private var liveRequestID: UUID?
    private var liveGeneration = UUID()
    private var liveUsed = false
    private var liveEnded = false
    private var liveDeadline: Task<Void, Never>?
    private struct LiveEpochInbox {
        let source: LiveSource
        var nextSequence: UInt64 = 0
        var deferred: [LiveLaneEvent] = []
    }
    private var liveEpochs: [UUID: LiveEpochInbox] = [:]
    private var retiredEpochs: Set<UUID> = []
    private var retiredLiveProcesses: [Process] = []
    private var liveBarriers = LiveBarrierReceipts()
    private var liveTerminalReceived = false
    private var deferredLiveTerminal: LiveSessionEvent?

    func beginLive(_ input: LiveSessionBegin) throws -> AsyncThrowingStream<LiveSessionEvent, Error> {
        guard role == .live, !liveUsed, !liveEnded else { throw MLHostError.protocolViolation }
        guard input.isValid else { throw LiveProtocolError.invalidConfiguration }
        let id = UUID()
        let envelope = RequestEnvelope(id: id, request: .live(.begin(input)))
        try validateLiveFrame(envelope)
        try ensureRunning()
        liveUsed = true; liveBegin = input; liveRequestID = id
        liveGeneration = UUID(); let generation = liveGeneration
        for epoch in input.epochs { liveEpochs[epoch.id] = .init(source: epoch.source) }
        let (stream, continuation) = AsyncThrowingStream<LiveSessionEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(liveEventLimits.queued))
        liveStream = continuation
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination { Task { await self.abandonLive(generation) } }
        }
        write(envelope)
        return stream
    }

    func sendLive(_ request: LiveSessionRequest) async throws -> LiveSessionReply {
        guard role == .live, liveUsed, !liveEnded, !liveTerminalReceived, process?.isRunning == true else { throw MLHostError.protocolViolation }
        if case .begin = request { throw MLHostError.protocolViolation }
        guard pending.count < 128 else { failLive(MLHostError.protocolViolation); throw MLHostError.protocolViolation }
        let id = UUID()
        let envelope = RequestEnvelope(id: id, request: .live(request))
        try validateLiveFrame(envelope)
        if case .replaceEpoch(let identity, let oldID, let epoch) = request {
            guard identity == liveBegin?.identity, liveEpochs[oldID]?.source == epoch.source,
                  liveEpochs[epoch.id] == nil, !retiredEpochs.contains(epoch.id) else { throw LiveProtocolError.staleScope }
            liveEpochs[epoch.id] = .init(source: epoch.source)
        }
        if case .barrier(let barrier) = request {
            guard barrier.scope.identity == liveBegin?.identity,
                  liveEpochs[barrier.scope.epochID]?.source == barrier.scope.source,
                  !retiredEpochs.contains(barrier.scope.epochID) else { throw LiveProtocolError.staleScope }
            do { try liveBarriers.reserve(id,barrier: barrier) }
            catch { failLive(error); throw error }
        }
        return try await withCheckedThrowingContinuation { cont in
            let resolved = ResolveOnce()
            pending[id] = Pending(onEvent: { event in
                switch event {
                case .live(.reply(let reply)): if resolved.tryResolve() { cont.resume(returning: reply) }
                case .finished: if resolved.tryResolve() { cont.resume(throwing: MLHostError.protocolViolation) }
                default: if resolved.tryResolve() { cont.resume(throwing: MLHostError.protocolViolation) }
                }
            }, onCrash: { error in if resolved.tryResolve() { cont.resume(throwing: error) } }, liveRequest: request)
            write(.init(id: id,request: .live(request)))
        }
    }

    func armLiveDeadline(_ duration: Duration) {
        guard role == .live, liveUsed, process != nil else { return }
        liveDeadline?.cancel(); let generation = liveGeneration
        liveDeadline = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            await self?.expireLive(generation)
        }
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
        guard role == .ordinary else { throw MLHostError.protocolViolation }
        if case .live = request { throw MLHostError.protocolViolation }
        let id = UUID()
        try await admitOrdinary(request,id: id)
        let expectsEvidence: Bool = switch request {
        case .transcribe: true
        case .diarize, .diarizeWithEmbeddings: true
        case .parakeetTranscribe(_, _, let diarize): diarize
        default: false
        }
        let trace = expectsEvidence ? PrivacyTrace.context.map { PrivacyMLTrace(context: $0) } : nil
        let progress = MLProgress.sink
        do {
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
                    onCrash: { error in if resolved.tryResolve() { cont.resume(throwing: error) } },
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
    func stream(_ request: MLRequest) async -> AsyncThrowingStream<String, Error> {
        let id = UUID()
        do {
            guard role == .ordinary else { throw MLHostError.protocolViolation }
            if case .live = request { throw MLHostError.protocolViolation }
            try await admitOrdinary(request,id: id)
        } catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
        let progress = MLProgress.sink
        return AsyncThrowingStream { continuation in
            guard role == .ordinary else { continuation.finish(throwing: MLHostError.protocolViolation); return }
            if case .live = request { continuation.finish(throwing: MLHostError.protocolViolation); return }
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
                onCrash: { continuation.finish(throwing: $0) }
            )
            continuation.onTermination = { @Sendable _ in
                Task { await self.send(.cancel, id: id) }
            }
            write(RequestEnvelope(id: id, request: request))
        }
    }

    func shutdown() {
        if role == .live { failLive(MLHostError.helperCrashed); return }
        retireOrdinaryProcess()
        stdinHandle = nil
        ingestContinuation?.finish()
        ingestContinuation = nil
        // The retired process's exit is ignored below, so fail its callers here.
        let dead = pending
        pending.removeAll()
        for (_, p) in dead { p.onCrash(MLHostError.helperCrashed) }
    }

    /// Resource ownership needs an exit receipt, including a process already
    /// killed by its deadline. This wait runs off actor and never delays audio
    /// closure; the capture coordinator releases its lease in a separate task.
    func shutdownLiveAndWaitForExit() async {
        guard role == .live else { return }
        failLive(MLHostError.helperCrashed)
        let retired = retiredLiveProcesses
        await Task.detached { for child in retired { child.waitUntilExit() } }.value
        retiredLiveProcesses.removeAll { child in retired.contains { $0 === child } }
    }

    /// Freeze process generation around the policy await. A late reservation
    /// cannot dispatch into a child whose idle retirement has already begun.
    private func admitOrdinary(_ request: MLRequest,id: UUID) async throws {
        while true {
            try Task.checkCancellation()
            if let child = process, !child.isRunning { handleTermination(of: child) }
            if nativeJobs.count >= 96, pending.isEmpty, activeNativeJobs.isEmpty { retireOrdinaryProcess() }
            let generation = ordinaryGeneration
            if let retirement = ordinaryRetirement {
                await retirement.value
                await retirementWaitDelivery?()
            }
            guard generation == ordinaryGeneration else { continue }
            let lease = try await resourceAdmission?.acquire(owner: id,request: request)
            guard generation == ordinaryGeneration, !Task.isCancelled else {
                if let lease { await resourceAdmission?.policy.releaseJob(lease) }
                try Task.checkCancellation(); continue
            }
            do { try ensureRunning() }
            catch { if let lease { await resourceAdmission?.policy.releaseJob(lease) }; throw error }
            if let lease, let process, let resourceAdmission {
                nativeJobs[id] = .init(lease: lease,process: process,policy: resourceAdmission.policy)
                activeNativeJobs.insert(id)
            }
            return
        }
    }

    func prepareForLiveCapture() async {
        guard role == .ordinary else { return }
        while true {
            guard pending.isEmpty, activeNativeJobs.isEmpty else { return }
            if process != nil { retireOrdinaryProcess() }
            let generation = ordinaryGeneration
            if let retirement = ordinaryRetirement {
                await retirement.value
                await retirementWaitDelivery?()
            }
            guard generation == ordinaryGeneration else { continue }
            // Another waiter may have used the same completed retirement to
            // launch a child. Recheck its actual work and residency before return.
            guard pending.isEmpty, activeNativeJobs.isEmpty else { return }
            if process != nil { continue }
            return
        }
    }

    private func ordinaryRequestFinished(_ id: UUID) {
        activeNativeJobs.remove(id)
        // Already-waiting successors cannot return to the admission threshold
        // check until these retained permits are released. Rotate on the last
        // actual completion as well as on a later, newly arriving request.
        if nativeJobs.count >= 96, pending.isEmpty, activeNativeJobs.isEmpty {
            retireOrdinaryProcess(); return
        }
        guard let admission = resourceAdmission else { return }
        let generation = ordinaryGeneration
        Task { [weak self] in
            guard await admission.policy.hasCaptureReservation else { return }
            await self?.retireOrdinaryIfIdle(generation: generation)
        }
    }
    private func retireOrdinaryIfIdle(generation: UUID) {
        guard generation == ordinaryGeneration, pending.isEmpty, activeNativeJobs.isEmpty else { return }
        retireOrdinaryProcess()
    }
    private func retireOrdinaryProcess() {
        ordinaryGeneration = UUID()
        let child = process; process = nil
        stdinHandle = nil
        ingestContinuation?.finish(); ingestContinuation = nil
        let receipts = nativeJobs.values.filter { child == nil || $0.process === child }
        for receipt in receipts { nativeJobs[receipt.lease.owner] = nil; activeNativeJobs.remove(receipt.lease.owner) }
        if let child, child.isRunning { child.terminate() }
        let previous = ordinaryRetirement
        ordinaryRetirement = Task {
            await previous?.value
            for receipt in receipts { await receipt.retire().value }
            if let child { await Task.detached { child.waitUntilExit() }.value }
        }
    }

    // MARK: process lifecycle

    private func ensureRunning() throws {
        if process?.isRunning == true { return }
        if role == .live, liveUsed { throw MLHostError.helperCrashed }
        // Foundation's termination callback may still be queued. Settle the
        // exited owner's callers before replacing the process dictionary owner.
        if let exited = process, role == .ordinary { handleTermination(of: exited) }
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = (role == .live ? ["--nemotron-live"] : []) + ["--support-base", supportBase.path]
        proc.environment = LiveASRIdentity.environment(inherited: ProcessInfo.processInfo.environment,extra: extraEnvironment,live: role == .live)

        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // stderr inherited so the helper's OSLog/stderr surfaces.

        // Serial consumer: chunks are ingested strictly in arrival order.
        ingestContinuation?.finish()
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: role == .live ? .bufferingOldest(8) : .unbounded)
        self.ingestContinuation = continuation
        Task { [weak self] in
            for await data in stream { await self?.ingest(data,from: proc) }
        }
        if role == .live {
            let latch = LiveReadFailureLatch()
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, continuation] handle in
                do {
                    guard let data = try LiveFrameReader.readChunk(from: handle) else { handle.readabilityHandler = nil; return }
                    if case .dropped = continuation.yield(data), latch.claim() {
                        continuation.finish(); Task { await self?.failLive(MLHostError.protocolViolation) }
                    }
                } catch {
                    if latch.claim() { continuation.finish(); Task { await self?.failLive(MLHostError.helperCrashed) } }
                }
            }
        } else {
            stdoutPipe.fileHandleForReading.readabilityHandler = { [continuation] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                continuation.yield(data)
            }
        }
        let terminationDelivery = terminationDelivery
        proc.terminationHandler = { [weak self] exited in
            Task { await terminationDelivery(); await self?.handleTermination(of: exited) }
        }
        do {
            try proc.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish(); ingestContinuation = nil
            throw MLHostError.helperUnavailable
        }
        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.reader = FrameReader()
        if role == .live {
            liveReader = LiveFrameReader()
            liveWriter = LivePipeWriter(handle: stdinPipe.fileHandleForWriting) { [weak self] in
                Task { await self?.failLive(MLHostError.helperCrashed) }
            }
        }
    }

    private func send(_ request: MLRequest, id: UUID) {
        write(RequestEnvelope(id: id, request: request))
    }

    private func ingest(_ data: Data,from child: Process) {
        guard child === process else { return }
        if role == .live { ingestLive(data); return }
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
                case .finished, .error:
                    pending[env.id] = nil
                    ordinaryRequestFinished(env.id)
                default: break
                }
            }
        }
    }

    private func handleTermination(of exited: Process) {
        let owned = nativeJobs.filter { $0.value.process === exited }
        for (id,receipt) in owned { activeNativeJobs.remove(id); nativeJobs[id] = nil; receipt.retire() }
        // A retired helper can exit after its replacement launched; only the
        // current process's exit may clear state and fail pending requests.
        guard exited === process else { return }
        if role == .live { failLive(MLHostError.helperCrashed); return }
        ordinaryGeneration = UUID()
        let dead = pending
        pending.removeAll()
        process = nil
        stdinHandle = nil
        ingestContinuation?.finish(); ingestContinuation = nil
        for (_, p) in dead { p.onCrash(MLHostError.helperCrashed) }
    }

    private func write(_ envelope: RequestEnvelope) {
        if role == .live {
            guard let payload = try? frameEncoder.encode(envelope), payload.count <= LiveFrameReader.maximumFrameBytes,
                  liveWriter?.enqueue(FrameCodec.encode(payload)) == true else { failLive(MLHostError.protocolViolation); return }
            return
        }
        guard let stdinHandle, let payload = try? frameEncoder.encode(envelope) else { return }
        stdinHandle.write(FrameCodec.encode(payload))
    }

    private func validateLiveFrame(_ envelope: RequestEnvelope) throws {
        guard try frameEncoder.encode(envelope).count <= LiveFrameReader.maximumFrameBytes else { throw LiveProtocolError.oversizedFrame }
    }

    private func abandonLive(_ generation: UUID) {
        guard generation == liveGeneration else { return }
        failLive(MLHostError.helperCrashed)
    }

    private func expireLive(_ generation: UUID) {
        guard generation == liveGeneration, process != nil else { return }
        failLive(MLHostError.liveDeadline)
    }

    private func stopLiveProcess() {
        liveDeadline?.cancel(); liveDeadline = nil
        if let process, !retiredLiveProcesses.contains(where: { $0 === process }) { retiredLiveProcesses.append(process) }
        if let process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process = nil
        liveWriter?.retire(); liveWriter = nil; stdinHandle = nil
        ingestContinuation?.finish(); ingestContinuation = nil
    }

    private func failLive(_ error: Error) {
        guard role == .live else { return }
        liveEnded = true
        liveBarriers.removeAll(); deferredLiveTerminal = nil
        for epoch in liveEpochs.keys { liveEpochs[epoch]?.deferred.removeAll() }
        liveStream?.finish(throwing: error); liveStream = nil
        let dead = pending; pending.removeAll()
        stopLiveProcess()
        for p in dead.values { p.onCrash(error) }
    }

    private func endLive(_ error: Error? = nil) {
        liveEnded = true
        if let error { liveStream?.finish(throwing: error) } else { liveStream?.finish() }
        liveStream = nil
        // A terminal session event can precede the final command's reply. Keep
        // reading until its correlated ack/finished pair has drained.
        if pending.isEmpty { stopLiveProcess() }
    }

    private func ingestLive(_ data: Data) {
        guard process != nil else { return }
        do {
            for frame in try liveReader.feed(data) {
                let envelope = try frameDecoder.decode(EventEnvelope.self,from: frame)
                guard envelope.channel == .live else { throw MLHostError.protocolViolation }
                if envelope.id == liveRequestID {
                    switch envelope.event {
                    case .live(.reply(.accepted)): break
                    case .live(.reply(.rejected(let error))): failLive(error)
                    case .live(.event(let event)): try receiveLive(event)
                    default: throw MLHostError.protocolViolation
                    }
                } else if var inbox = pending[envelope.id] {
                    switch envelope.event {
                    case .live(.reply(let reply)):
                        guard !inbox.liveReplied, let request = inbox.liveRequest else { throw MLHostError.protocolViolation }
                        try receiveLiveReply(envelope.id,request: request,reply: reply)
                        inbox.liveReplied = true; pending[envelope.id] = inbox
                        inbox.onEvent(envelope.event)
                    case .finished:
                        guard inbox.liveReplied else { throw MLHostError.protocolViolation }
                        inbox.onEvent(envelope.event)
                    default: throw MLHostError.protocolViolation
                    }
                    if case .finished = envelope.event { pending[envelope.id] = nil }
                } else { throw MLHostError.protocolViolation }
            }
            if liveEnded, pending.isEmpty { stopLiveProcess() }
        } catch { failLive(error is LiveProtocolError ? error : MLHostError.protocolViolation) }
    }

    private func receiveLive(_ event: LiveSessionEvent) throws {
        guard let begin = liveBegin else { throw MLHostError.protocolViolation }
        // Check decoded size before any stream or pre-reply inbox can retain it.
        // One transient decoded frame is separately bounded by the wire limit.
        if let limit = liveEventLimits.accountedBytes {
            guard (try? LiveArtifactEncoding.estimatedBytes(event, limit: max(1, limit / 4))) != nil else {
                throw MLHostError.protocolViolation
            }
        }
        switch event {
        case .lane(let lane):
            guard lane.scope.identity == begin.identity else { throw MLHostError.protocolViolation }
            if retiredEpochs.contains(lane.scope.epochID) { return }
            guard !liveTerminalReceived else { throw MLHostError.protocolViolation }
            guard var inbox = liveEpochs[lane.scope.epochID], inbox.source == lane.scope.source,
                  lane.sequence == inbox.nextSequence, lane.sequence < .max else { throw MLHostError.protocolViolation }
            // Embedded evidence must have the same source and epoch as its wire scope.
            switch lane.payload {
            case .partial(let partial):
                guard partial.epochID == lane.scope.epochID, partial.source == lane.scope.source else { throw MLHostError.protocolViolation }
            case .committed(let segment):
                guard segment.id.epochID == lane.scope.epochID, segment.source == lane.scope.source else { throw MLHostError.protocolViolation }
            case .settled(let interval):
                guard interval.epochID == lane.scope.epochID, interval.source == lane.scope.source else { throw MLHostError.protocolViolation }
            case .barrierCompleted(let id,let kind,let end):
                try liveBarriers.complete(id,scope: lane.scope,kind: kind,end: end)
                // A pre-reply completion must remain provable even if accepted
                // outer replacement later retires its whole epoch and buffer.
                pending[id]?.liveCompletionSeen = true
            default: break
            }
            inbox.nextSequence += 1
            // A completion can overtake its command reply. Preserve this lane's
            // suffix until acceptance; the other source keeps publishing.
            if !inbox.deferred.isEmpty || { if case .barrierCompleted(let id,_,_) = lane.payload { !liveBarriers.canPublish(id) } else { false } }() {
                guard inbox.deferred.count < 16 else { throw MLHostError.protocolViolation }
                if let limit = liveEventLimits.deferred {
                    guard liveEpochs.values.reduce(0, { $0 + $1.deferred.count }) < limit else { throw MLHostError.protocolViolation }
                }
                inbox.deferred.append(lane); liveEpochs[lane.scope.epochID] = inbox
                try drainLiveEpoch(lane.scope.epochID)
                return
            }
            liveEpochs[lane.scope.epochID] = inbox
            try publishLive(event)
        case .finished(let identity), .failed(let identity,_):
            guard identity == begin.identity, !liveTerminalReceived else { throw MLHostError.protocolViolation }
            liveTerminalReceived = true
            if case .finished = event, liveEpochs.values.contains(where: { !$0.deferred.isEmpty }) {
                deferredLiveTerminal = event; return
            }
            try publishLive(event)
        }
    }

    private func receiveLiveReply(_ id: UUID, request: LiveSessionRequest, reply: LiveSessionReply) throws {
        if pending[id]?.liveCompletionSeen == true, reply != .accepted { throw MLHostError.protocolViolation }
        switch request {
        case .barrier(let barrier):
            if !retiredEpochs.contains(barrier.scope.epochID) {
                try liveBarriers.reply(id,value: reply)
                try drainLiveEpoch(barrier.scope.epochID)
            }
        case .replaceEpoch(_,let oldID,let epoch):
            if reply == .accepted {
                liveBarriers.retire(oldID); liveEpochs[oldID] = nil; retiredEpochs.insert(oldID)
            } else {
                // A rejected command cannot have legitimately started its decoder.
                guard liveEpochs[epoch.id]?.nextSequence == 0 else { throw MLHostError.protocolViolation }
                liveEpochs[epoch.id] = nil
            }
        default: break
        }
        try publishDeferredLiveTerminal()
    }

    private func drainLiveEpoch(_ epochID: UUID) throws {
        while let lane = liveEpochs[epochID]?.deferred.first {
            if case .barrierCompleted(let id,_,_) = lane.payload, !liveBarriers.canPublish(id) { return }
            liveEpochs[epochID]?.deferred.removeFirst()
            try publishLive(.lane(lane))
        }
        try publishDeferredLiveTerminal()
    }

    private func publishDeferredLiveTerminal() throws {
        guard let terminal = deferredLiveTerminal, liveEpochs.values.allSatisfy({ $0.deferred.isEmpty }) else { return }
        deferredLiveTerminal = nil; try publishLive(terminal)
    }

    private func publishLive(_ event: LiveSessionEvent) throws {
        if case .lane(let lane) = event, case .barrierCompleted(let id,_,_) = lane.payload { try liveBarriers.published(id) }
        guard let liveStream else { return }
        if case .dropped = liveStream.yield(event) { throw MLHostError.protocolViolation }
        switch event {
        case .finished: endLive()
        case .failed(_,let error): endLive(error)
        default: break
        }
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
