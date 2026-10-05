import Foundation
import dBriefWire

/// A dedicated process owns one shared immutable factory and a serial pump per
/// source. Admission never awaits native work; no ordinary backend mutex is used.
actor LiveASROrchestrator {
    static let maximumEpochsPerHelper = 4096
    typealias Loader = @Sendable (LiveASRConfiguration) async throws -> any NemotronDecoderMaking
    typealias DiarizationLoader = @Sendable (LiveDiarizationConfiguration) async throws -> any LiveDiarizationDriving
    typealias DiarizationEmit = @Sendable (LiveDiarizationEvent) -> Bool
    typealias VADLoader = @Sendable (LiveSessionBegin) async throws -> LiveVADModelFactory
    private enum State { case loading, active, retiring, paused, needsReplacement, closed }
    private final class OriginalPacket: Sendable {
        let samples: [Float], start: Int64, receipt: LiveSharedPacketReceipt
        let disposed: @Sendable (LiveLaneScope) -> Void
        init(samples: [Float],start: Int64,receipt: LiveSharedPacketReceipt,disposed: @escaping @Sendable (LiveLaneScope) -> Void) {
            self.samples = samples; self.start = start; self.receipt = receipt; self.disposed = disposed
        }
        deinit { disposed(receipt.scope) }
    }
    private enum Command { case packet([Float], Int64), configuredPacket(OriginalPacket), barrier(UUID, LiveFinishBarrier) }
    private struct Work: Sendable {
        let scope: LiveLaneScope; let id: UUID; let task: Task<Void, Never>; let packet: LiveSharedPacketToken?
        init(scope: LiveLaneScope,id: UUID,task: Task<Void,Never>,packet: LiveSharedPacketToken? = nil) {
            self.scope = scope; self.id = id; self.task = task; self.packet = packet
        }
    }
    private struct RetirementResult: Sendable { let vadRetired: Bool }
    private struct Retirement: Sendable {
        let scope: LiveLaneScope; let id: UUID; let task: Task<RetirementResult,Never>
    }
    private struct Installation: Sendable {
        let id: UUID, wireOld: LiveLaneScope, nativeFrom: LiveLaneScope, new: LiveLaneScope
    }
    private struct Lane {
        let epoch: LiveEpoch
        var state = State.loading
        var captured: Int64 = 0, admitted: Int64 = 0, consumed: Int64 = 0, processed: Int64 = 0, settled: Int64 = 0
        var queued: Int64 = 0, inFlight: Int64 = 0
        var nextPacket: UInt64 = 0, nextEvent: UInt64 = 0, nextSegment: UInt64 = 0, partialRevision: UInt64 = 0
        var commands: [Command] = []
        var barrier: (UUID, LiveFinishBarrier)?
        var completedBarrier: (UUID, LiveFinishBarrier)?
        var closing = false
        var gapReason = LiveGapReason.preparation
        var generation: UUID?
        var session: NemotronDecoderSession?
        var asrInputRetired = false
        var vadInputRetired = false, runtimeSetupPending = false
        var nativeScope: LiveLaneScope?
        var sharedInput: LiveSharedInputLedger?
        var vadContext: UUID?, vadEnd: Int64 = 0
        var vadPreparing = false, vadRetired = false, vadActivated = false
        var partialTask: Task<Void, Never>?
        var partialContinuation: AsyncStream<(UUID, String)>.Continuation?
    }
    private enum DiarizationPhase { case preparing, awaitingInput, active, pausing, paused, finishing, retired }
    private enum DiarizationOutcome: Sendable {
        case loaded(any LiveDiarizationDriving), batch(LiveDiarizationBatch, terminal: Bool), paused, resumed, failed
    }
    private struct DiarizationWork: Sendable { let id: UUID; let task: Task<DiarizationOutcome, Never> }
    private struct DiarizationRange { let start: Int64; var end: Int64 }
    private final class DiarizationWitness: LiveDiarizationResourceWitness { let ownerID: UUID; init(_ id: UUID) { ownerID = id } }
    private struct Diarization {
        let ownerID: UUID, requestID: UUID, requestedScope: LiveLaneScope, configuration: LiveDiarizationConfiguration
        var scope: LiveLaneScope
        var phase = DiarizationPhase.preparing
        var contextID: UUID?, confirmed = false, nextEvent: UInt64 = 0
        var driver: LiveDiarizationDriverOwnership?, session: LiveDiarizationSession?, work: DiarizationWork?
        var ranges: [UUID: DiarizationRange] = [:]
        var streamEnd: Int64 = 0, frameEnd: Int64 = 0, lastMeetingEnd: Int64?
        var frames: [LiveDiarizationFrame]?, frameCursor = 0
        var outstanding: UInt64?, lastAcknowledged: UInt64?
        var pausePending = false, resumePending: (LiveLaneScope, LiveLaneScope)?, finishPending = false, terminalProduced = false
        var joined = false
    }
    private let diarizationLoader: DiarizationLoader?
    private let diarizationEmit: DiarizationEmit?
    private var diarization: Diarization?
    private var diarizationRetirement: (UUID, Task<Void, Never>, LiveDiarizationEvent.RetirementReason)?
    private let loader: Loader
    private let vadLoader: VADLoader?
    private let emit: @Sendable (LiveSessionEvent) -> Void
    private let testingBeforeRetirement: @Sendable (LiveLaneScope) async -> Void
    private let testingBeforeWorkReturn: @Sendable (LiveLaneScope) async -> Void
    private let testingBeforeVADActivation: @Sendable (LiveLaneScope) async -> Void
    private let testingAfterLoadingReturn: @Sendable () -> Void
    private let epochLimit: Int
    private let testingPacketDisposed: @Sendable (LiveLaneScope) -> Void
    private let testingBeforeInstall: @Sendable (LiveLaneScope,LiveLaneScope) async -> Void
    private let testingAfterInstall: @Sendable (LiveLaneScope,LiveLaneScope) async -> Void
    private var begin: LiveSessionBegin?
    private var beginRequestID: UUID?
    private var factory: (any NemotronDecoderMaking)?
    private var loading: Task<Void, Never>?
    private var vadRuntime: LiveVADModuleRuntime?
    private var lanes: [LiveSource: Lane] = [:]
    private var works: [LiveSource: Work] = [:]
    private var retirements: [LiveSource: Retirement] = [:]
    private var installations: [LiveSource: Installation] = [:]
    private var knownEpochs: Set<UUID> = []
    private var closed = false

    init(loader: @escaping Loader, vadLoader: VADLoader? = nil, diarizationLoader: DiarizationLoader? = nil,
         diarizationEmit: DiarizationEmit? = nil, emit: @escaping @Sendable (LiveSessionEvent) -> Void,
         testingBeforeRetirement: @escaping @Sendable (LiveLaneScope) async -> Void = { _ in },
         testingBeforeWorkReturn: @escaping @Sendable (LiveLaneScope) async -> Void = { _ in },
         testingBeforeVADActivation: @escaping @Sendable (LiveLaneScope) async -> Void = { _ in },
         testingAfterLoadingReturn: @escaping @Sendable () -> Void = {},
         testingEpochLimit: Int = maximumEpochsPerHelper,
         testingPacketDisposed: @escaping @Sendable (LiveLaneScope) -> Void = { _ in },
         testingBeforeInstall: @escaping @Sendable (LiveLaneScope,LiveLaneScope) async -> Void = { _,_ in },
         testingAfterInstall: @escaping @Sendable (LiveLaneScope,LiveLaneScope) async -> Void = { _,_ in }) {
        self.loader = loader; self.vadLoader = vadLoader; self.emit = emit
        self.diarizationLoader = diarizationLoader; self.diarizationEmit = diarizationEmit
        self.testingBeforeRetirement = testingBeforeRetirement; self.testingBeforeWorkReturn = testingBeforeWorkReturn
        self.testingBeforeVADActivation = testingBeforeVADActivation
        self.testingAfterLoadingReturn = testingAfterLoadingReturn
        self.epochLimit = min(max(0,testingEpochLimit),Self.maximumEpochsPerHelper)
        self.testingPacketDisposed = testingPacketDisposed
        self.testingBeforeInstall = testingBeforeInstall; self.testingAfterInstall = testingAfterInstall
    }

    func handle(_ request: LiveSessionRequest, requestID: UUID) async -> LiveSessionReply {
        switch request {
        case .begin(let input):
            if let begin { return begin == input && beginRequestID == requestID ? .accepted : .rejected(.closed) }
            guard !closed, input.isValid, input.epochs.count <= epochLimit else { return .rejected(.invalidConfiguration) }
            // Configured sessions require the trusted read-only native consumer.
            guard input.vad == nil || vadLoader != nil else { return .rejected(.unavailable) }
            begin = input; beginRequestID = requestID
            for epoch in input.epochs {
                var lane = Lane(epoch: epoch); lane.runtimeSetupPending = input.vad != nil
                lanes[epoch.source] = lane; knownEpochs.insert(epoch.id)
                if let vad = input.vad { send(epoch.source,.vad(.preparing(identity: vad.identity))); lanes[epoch.source]?.vadPreparing = true }
            }
            let task = Task {
                do {
                    try Task.checkCancellation()
                    guard !self.closed else { return }
                    let factory = try await loader(input.configuration)
                    try Task.checkCancellation()
                    guard !self.closed else { return }
                    if let vadLoader, input.vad != nil {
                        let pool: LiveVADModelFactory?
                        do { pool = try await vadLoader(input) } catch { pool = nil }
                        try Task.checkCancellation()
                        guard !self.closed else { return }
                        let runtime: LiveVADModuleRuntime
                        do { runtime = try LiveVADModuleRuntime(input: input,factory: pool) }
                        catch { runtime = try LiveVADModuleRuntime(input: input,factory: nil) }
                        await self.loadedConfigured(factory,runtime: runtime)
                    } else { self.loaded(factory) }
                }
                catch { self.loadFailed() }
            }
            loading = task
            Task { await task.value; self.testingAfterLoadingReturn() }
            return .accepted
        case .diarizationControl(let control):
            guard let frozen = begin?.diarization, begin?.identity == control.identity,
                  frozen.ownerID == control.ownerID else { return .rejected(.staleScope) }
            switch control.payload {
            case .prepare(let epoch):
                return prepareDiarization(scope: .init(identity: control.identity, source: .system, epochID: epoch),
                    owner: control.ownerID, configuration: frozen.configuration, requestID: requestID)
            case .acknowledge(let context):
                return await handle(.acknowledgeDiarization(identity: control.identity, ownerID: control.ownerID, contextID: context), requestID: requestID)
            case .acknowledgePosterior(let context, let sequence):
                return await handle(.acknowledgeDiarizationPosterior(identity: control.identity, ownerID: control.ownerID,
                    contextID: context, sequence: sequence), requestID: requestID)
            case .retire:
                return await handle(.retireDiarization(identity: control.identity, ownerID: control.ownerID), requestID: requestID)
            }
        case .prepareDiarization(let scope, let owner, let configuration):
            return prepareDiarization(scope: scope, owner: owner, configuration: configuration, requestID: requestID)
        case .acknowledgeDiarization(let identity, let owner, let context):
            guard var current = diarization, current.scope.identity == identity, current.ownerID == owner,
                  current.contextID == context, current.phase != .retired else { return .rejected(.staleScope) }
            current.confirmed = true; diarization = current; publishDiarization(); return .accepted
        case .acknowledgeDiarizationPosterior(let identity, let owner, let context, let sequence):
            guard var current = diarization, current.scope.identity == identity, current.ownerID == owner,
                  current.contextID == context, current.phase != .retired else { return .rejected(.staleScope) }
            if current.lastAcknowledged == sequence { return .accepted }
            guard current.outstanding == sequence else { return .rejected(.outOfOrder) }
            current.lastAcknowledged = sequence; current.outstanding = nil; diarization = current
            publishDiarization(); return .accepted
        case .retireDiarization(let identity, let owner):
            guard let current = diarization, current.scope.identity == identity, current.ownerID == owner else { return .rejected(.staleScope) }
            retireDiarization(.pressure); return .accepted
        case .cancel(let identity):
            guard begin?.identity == identity else { return .rejected(.staleScope) }
            retireDiarization(.stopped)
            if closed { return .accepted }
            loading?.cancel()
            for source in lanes.keys where lanes[source]?.state != .closed {
                cut(source, reason: .stopped); lanes[source]?.state = .closed
                send(source, .closed(sampleEnd: lanes[source]!.captured))
            }
            closed = true; emit(.finished(identity)); return .accepted
        case .replaceEpoch(let identity, let oldID, let epoch):
            if begin?.vad != nil { return await replaceConfigured(identity: identity,oldID: oldID,epoch: epoch) }
            guard !closed, let begin, begin.identity == identity, let old = lanes[epoch.source], old.epoch.id == oldID else { return .rejected(.staleScope) }
            guard old.state == .needsReplacement || old.state == .paused, old.asrInputRetired,
                  works[epoch.source] == nil, retirements[epoch.source] == nil, factory != nil else { return .rejected(.unavailable) }
            guard !knownEpochs.contains(epoch.id), LiveSessionBegin(identity: identity, configuration: begin.configuration, epochs: [epoch],vad: begin.vad).isValid else { return .rejected(.invalidConfiguration) }
            guard knownEpochs.count < epochLimit else { return .rejected(.unavailable) }
            old.partialTask?.cancel(); old.partialContinuation?.finish()
            knownEpochs.insert(epoch.id); lanes[epoch.source] = Lane(epoch: epoch)
            replaceDiarizationEpoch(previous: .init(identity: identity, source: epoch.source, epochID: oldID), epoch: epoch, paused: old.state == .paused)
            kick(epoch.source)
            return .accepted
        case .packet(let packet):
            guard !closed, matches(packet.scope), let current = lanes[packet.scope.source] else { return .rejected(.staleScope) }
            guard current.state != .closed && current.state != .paused && !current.closing else { return .rejected(.closed) }
            let samples: [Float]
            do { samples = try packet.decodedSamples() } catch { return .rejected(.invalidPacket) }
            guard packet.sequence == current.nextPacket, packet.startSample == current.captured else { return .rejected(.outOfOrder) }
            let source = packet.scope.source, end = packet.startSample + Int64(samples.count)
            lanes[source]?.captured = end; lanes[source]?.nextPacket += 1
            guard current.state == .active else { cut(source, reason: current.gapReason); return .rejected(.unavailable) }
            let common = current.sharedInput?.progress.consumedEnd ?? current.consumed
            guard current.admitted - common + Int64(samples.count) <= Int64(begin!.configuration.pendingSampleLimit),
                  current.commands.count < 64 else { cut(source, reason: .overload); return .rejected(.unavailable) }
            if begin?.vad != nil {
                guard var ledger = lanes[source]?.sharedInput else { cut(source,reason: .engineRestart); return .rejected(.unavailable) }
                do {
                    let receipt = try ledger.admit(scope: packet.scope,startSample: packet.startSample,sampleCount: samples.count)
                    lanes[source]?.sharedInput = ledger
                    lanes[source]?.commands.append(.configuredPacket(.init(samples: samples,start: packet.startSample,receipt: receipt,disposed: testingPacketDisposed)))
                } catch { cut(source,reason: .overload); return .rejected(.unavailable) }
            } else { lanes[source]?.commands.append(.packet(samples, packet.startSample)) }
            lanes[source]?.admitted = end; lanes[source]?.queued += Int64(samples.count)
            send(source, .admitted(packetSequence: packet.sequence, sampleEnd: end)); progress(source); kick(source)
            return .accepted
        case .cut(let scope, let nextSequence, let end, let reason):
            guard !closed, matches(scope), let lane = lanes[scope.source] else { return .rejected(.staleScope) }
            guard lane.state != .closed, end >= lane.captured, nextSequence >= lane.nextPacket, nextSequence < .max else { return .rejected(.outOfOrder) }
            if let pending = lane.barrier, pending.1.kind != .utterance {
                guard end == pending.1.sampleEnd, nextSequence == pending.1.nextPacketSequence else { return .rejected(.outOfOrder) }
            }
            lanes[scope.source]?.captured = end; lanes[scope.source]?.nextPacket = nextSequence
            cut(scope.source, reason: reason); return .accepted
        case .barrier(let barrier):
            guard matches(barrier.scope), let lane = lanes[barrier.scope.source] else { return .rejected(.staleScope) }
            if let prior = lane.completedBarrier, prior.0 == requestID, prior.1 == barrier { return .accepted }
            guard !closed else { return .rejected(.closed) }
            if let prior = lane.barrier { return prior.0 == requestID && prior.1 == barrier ? .accepted : .rejected(.outOfOrder) }
            guard barrier.sampleEnd == lane.captured, barrier.nextPacketSequence == lane.nextPacket else { return .rejected(.outOfOrder) }
            if lane.state == .paused {
                guard barrier.kind == .finish, lane.settled == lane.captured, inputRetired(lane) else { return .rejected(.closed) }
                // Pause already flushed this exact prefix. Closing it cannot
                // call finish on the retired decoder or create another segment.
                finishBarrier(barrier.scope.source,id: requestID,barrier: barrier)
                return .accepted
            }
            if lane.state == .needsReplacement || lane.state == .loading {
                guard barrier.kind != .utterance else { return .rejected(.unavailable) }
                cut(barrier.scope.source, reason: .stopped)
                lanes[barrier.scope.source]?.barrier = (requestID,barrier)
                lanes[barrier.scope.source]?.closing = true
                if let current = lanes[barrier.scope.source], inputRetired(current) {
                    finishBarrier(barrier.scope.source,id: requestID,barrier: barrier)
                }
                return .accepted
            }
            guard lane.state == .active else { return .rejected(.closed) }
            lanes[barrier.scope.source]?.barrier = (requestID, barrier)
            lanes[barrier.scope.source]?.closing = barrier.kind != .utterance
            lanes[barrier.scope.source]?.commands.append(.barrier(requestID, barrier)); kick(barrier.scope.source)
            return .accepted
        }
    }

    private func matches(_ scope: LiveLaneScope) -> Bool { begin?.identity == scope.identity && lanes[scope.source]?.epoch.id == scope.epochID }
    private func scope(_ source: LiveSource) -> LiveLaneScope { .init(identity: begin!.identity, source: source, epochID: lanes[source]!.epoch.id) }
    private func loaded(_ factory: any NemotronDecoderMaking) {
        guard !closed else { return }; self.factory = factory; loading = nil
        for source in lanes.keys {
            if lanes[source]?.state == .loading { kick(source) }
            else if lanes[source]?.state == .needsReplacement { send(source, .needsEpochReplacement) }
        }
    }
    private func loadFailed() {
        retireDiarization(.failed)
        guard !closed, let begin else { return }
        for source in lanes.keys { cut(source, reason: .preparation) }
        closed = true; emit(.failed(begin.identity, .unavailable))
    }
    private func send(_ source: LiveSource, _ payload: LiveLaneEvent.Payload) {
        guard let lane = lanes[source], let begin else { return }
        guard lane.nextEvent < .max else { closed = true; emit(.failed(begin.identity, .outputLimit)); return }
        lanes[source]?.nextEvent += 1
        emit(.lane(.init(scope: scope(source), sequence: lane.nextEvent, payload: payload)))
    }
    private func progress(_ source: LiveSource) {
        guard !closed, let lane = lanes[source], let begin, lane.state != .retiring, lane.state != .closed else { return }
        if let ledger = lane.sharedInput {
            let p = ledger.progress
            send(source,.progress(.init(capturedSampleEnd: lane.captured,admittedSampleEnd: p.admittedEnd,
                consumedSampleEnd: p.consumedEnd,queuedSamples: p.queuedSamples,inFlightSamples: p.inFlightSamples,
                heldSamples: p.heldSamples,creditSamples: lane.state == .active ? p.creditSamples : 0,
                asrConsumedSampleEnd: p.asrConsumedEnd)))
            return
        }
        let held = max(0, lane.processed - lane.consumed)
        let pending = lane.queued + lane.inFlight + held
        send(source, .progress(.init(capturedSampleEnd: lane.captured, admittedSampleEnd: lane.admitted,
            consumedSampleEnd: lane.consumed, queuedSamples: lane.queued, inFlightSamples: lane.inFlight, heldSamples: held,
            creditSamples: lane.state == .active ? max(0, Int64(begin.configuration.pendingSampleLimit) - pending) : 0,
            asrConsumedSampleEnd: lane.consumed)))
    }
    private func cut(_ source: LiveSource, reason: LiveGapReason) {
        if source == .system { retireDiarization(.discontinuity) }
        guard var lane = lanes[source], lane.state != .closed else { return }
        let first = lane.state != .needsReplacement
        lane.state = .needsReplacement; lane.gapReason = reason; lane.generation = nil
        lane.commands.removeAll(); lane.queued = 0
        if lane.barrier?.1.kind == .utterance { lane.barrier = nil }
        lane.closing = lane.barrier != nil
        lane.partialContinuation?.finish(); lane.partialTask?.cancel()
        let gap = lane.settled..<lane.captured; lane.settled = lane.captured; lanes[source] = lane
        logicalVADSeal(source)
        if first {
            works[source]?.task.cancel()
            startRetirement(source)
        }
        if !gap.isEmpty { send(source, .settled(.init(epochID: lane.epoch.id, source: source,
            range: .init(samples: .init(start: gap.lowerBound,end: gap.upperBound), meeting: nil), kind: .gap(reason)))) }
        if first { send(source, .needsEpochReplacement) }
        progress(source)
    }

    private func kick(_ source: LiveSource) {
        if begin?.vad != nil { kickConfigured(source); return }
        guard works[source] == nil, retirements[source] == nil, let factory, let begin, var lane = lanes[source], lane.state == .active || lane.state == .loading else { return }
        guard lane.generation == nil || !lane.commands.isEmpty else { return }
        let scope = self.scope(source), config = begin.configuration, workID = UUID()
        let session: NemotronDecoderSession
        if let existing = lane.session { session = existing }
        else {
            let (partials, continuation) = AsyncStream<(UUID,String)>.makeStream(bufferingPolicy: .bufferingNewest(1))
            session = NemotronDecoderSession(factory: factory) { event in
                if case .partial(let generation, let text) = event, text.utf8.count <= 8192 { continuation.yield((generation,text)) }
            }
            lane.session = session; lane.partialContinuation = continuation
            lane.partialTask = Task { for await (generation,text) in partials { self.partial(scope, generation: generation, text: text) } }
        }
        let generation = lane.generation, origin = lane.settled
        lanes[source] = lane
        let task = Task {
            await self.runWork(scope,workID: workID,session: session,config: config,generation: generation,origin: origin)
            await self.testingBeforeWorkReturn(scope)
        }
        works[source] = .init(scope: scope,id: workID,task: task)
        // No callback inside the work closure can clear this record. Even its
        // last callback precedes actual task-local input unwind.
        Task { await task.value; self.workReturned(scope,workID: workID) }
    }
    private func matchesWork(_ scope: LiveLaneScope, _ workID: UUID) -> Bool {
        matches(scope) && works[scope.source]?.scope == scope && works[scope.source]?.id == workID
    }
    private func runWork(_ scope: LiveLaneScope, workID: UUID, session: NemotronDecoderSession,
                         config: LiveASRConfiguration, generation: UUID?, origin: Int64) async {
        let source = scope.source
        do {
            var generation = generation
            let configuration = try NemotronDecoderConfiguration(language: .init(rawValue: config.language.rawValue)!, chunkMs: config.chunkMs)
            if generation == nil { generation = try await session.prepare(configuration: configuration, origin: origin)
                guard self.ready(scope, workID: workID, generation: generation!, origin: origin) else { return } }
            while let command = self.next(scope,workID: workID) {
                try Task.checkCancellation()
                switch command {
                case .configuredPacket: throw LiveProtocolError.invalidPacket
                case .packet(let samples, let start):
                    let native = try await session.append(samples: samples, startSample: start)
                    guard self.processed(scope, workID: workID, generation: generation!, end: start + Int64(samples.count), progress: native) else { return }
                    offerDiarization(scope: scope, samples: samples, start: start)
                case .barrier(let id, let barrier):
                    let result = try await session.finish(replacingDecoder: false)
                    guard self.commit(scope, workID: workID, generation: generation!, result: result, barrier: barrier) else { return }
                    if barrier.kind != .utterance {
                        lanes[source]?.state = .retiring
                        startRetirement(source)
                        return // The cleanup phase awaits this task, never vice versa.
                    }
                    self.finishBarrier(source,id: id,barrier: barrier)
                    generation = try await session.prepare(configuration: configuration, origin: barrier.sampleEnd)
                    guard self.ready(scope, workID: workID, generation: generation!, origin: barrier.sampleEnd) else { return }
                }
            }
        } catch { self.failed(scope,workID: workID) }
    }
    private func ready(_ scope: LiveLaneScope, workID: UUID, generation: UUID, origin: Int64) -> Bool {
        guard !closed, matchesWork(scope,workID), lanes[scope.source]?.state == .loading || lanes[scope.source]?.state == .active else { return false }
        lanes[scope.source]?.state = .active; lanes[scope.source]?.generation = generation
        send(scope.source,.ready(generation: generation,originSample: origin)); progress(scope.source); return true
    }
    private func next(_ scope: LiveLaneScope, workID: UUID) -> Command? {
        guard !closed, matchesWork(scope,workID), var lane = lanes[scope.source], lane.state == .active, !lane.commands.isEmpty else { return nil }
        let command = lane.commands.removeFirst()
        if case .packet(let samples, _) = command { lane.queued -= Int64(samples.count); lane.inFlight = Int64(samples.count) }
        lanes[scope.source] = lane; progress(scope.source); return command
    }
    private func processed(_ scope: LiveLaneScope, workID: UUID, generation: UUID, end: Int64, progress native: NemotronDecoderProgress) -> Bool {
        guard !closed, matchesWork(scope,workID), var lane = lanes[scope.source], lane.state == .active, lane.generation == generation else { return false }
        let consumed = lane.settled.addingReportingOverflow(native.consumedSamples)
        guard !consumed.overflow, consumed.partialValue >= lane.consumed, consumed.partialValue <= end,
              native.heldSamples == end - consumed.partialValue else { cut(scope.source,reason: .engineRestart); return false }
        lane.processed = end; lane.consumed = consumed.partialValue; lane.inFlight = 0
        lanes[scope.source] = lane; progress(scope.source); return true
    }
    private func partial(_ scope: LiveLaneScope, generation: UUID, text: String) {
        let end = lanes[scope.source]?.sharedInput?.progress.asrSubmittedEnd ??
            ((lanes[scope.source]?.processed ?? 0)+(lanes[scope.source]?.inFlight ?? 0))
        guard !closed, matches(scope), var lane = lanes[scope.source], lane.state == .active, lane.generation == generation,
              lane.partialRevision < .max, end > lane.settled else { return }
        lane.partialRevision += 1; lanes[scope.source] = lane
        send(scope.source,.partial(.init(epochID: scope.epochID,source: scope.source,revision: lane.partialRevision,
            samples: .init(start: lane.settled,end: end),text: text)))
    }
    private func commit(_ scope: LiveLaneScope, workID: UUID, generation: UUID, result: NemotronCommittedUtterance, barrier: LiveFinishBarrier) -> Bool {
        guard !closed, matchesWork(scope,workID), var lane = lanes[scope.source], lane.state == .active, lane.generation == generation,
              result.generation == generation, result.range.lowerBound == lane.settled, result.range.upperBound == barrier.sampleEnd,
              lane.processed == barrier.sampleEnd else { return false }
        guard result.output.text.utf8.count <= 8192, lane.nextSegment < .max else { cut(scope.source,reason: .engineRestart); return false }
        let range = LiveEvidenceRange(samples: result.range.isEmpty ? nil : .init(start: result.range.lowerBound,end: result.range.upperBound),meeting: nil)
        var payload: LiveLaneEvent.Payload?
        if !result.range.isEmpty {
            if result.output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Recognition absence supplies no acoustic silence certificate.
                // Settle the real processed prefix without cutting its source.
                payload = .settled(.init(epochID: scope.epochID,source: scope.source,range: range,kind: .gap(.unavailable)))
            } else {
                var words: [LiveWordSpan] = []
                for timing in result.output.timings.prefix(512) where !timing.token.isEmpty && timing.token.utf8.count <= 4096 {
                    let start = Int64((timing.startSeconds * 16000).rounded(.up)) + result.range.lowerBound
                    let end = Int64((timing.endSeconds * 16000).rounded(.down)) + result.range.lowerBound
                    if end > start { words.append(.init(text: timing.token,samples: .init(start: start,end: end))) }
                }
                func segment(_ words: [LiveWordSpan]) -> CommittedLiveSegment {
                    .init(id: .init(epochID: scope.epochID,index: lane.nextSegment),source: scope.source,range: range,text: result.output.text,
                        words: words,language: lane.epoch.language)
                }
                var value = segment(words)
                if (try? JSONEncoder().encode(value).count) ?? .max > 55000 { value = segment([]) }
                guard value.isValid else { cut(scope.source,reason: .engineRestart); return false }
                payload = .committed(attachingDiarization(value, scope: scope)); lane.nextSegment += 1
            }
        }
        lane.settled = barrier.sampleEnd; lane.consumed = barrier.sampleEnd; lane.generation = nil
        lanes[scope.source] = lane
        progress(scope.source) // Successful flush releases the held tail before settlement.
        if let payload { send(scope.source,payload) }
        return true
    }
    private func finishBarrier(_ source: LiveSource, id: UUID, barrier: LiveFinishBarrier) {
        orderedDiarizationBarrier(barrier)
        lanes[source]?.barrier = nil; lanes[source]?.completedBarrier = (id,barrier)
        send(source,.barrierCompleted(requestID: id,kind: barrier.kind,sampleEnd: barrier.sampleEnd))
        if barrier.kind != .utterance { lanes[source]?.partialTask?.cancel(); lanes[source]?.partialContinuation?.finish() }
        if barrier.kind == .pause { lanes[source]?.state = .paused }
        if barrier.kind == .finish { lanes[source]?.state = .closed; send(source,.closed(sampleEnd: barrier.sampleEnd)) }
        if lanes.values.allSatisfy({ $0.state == .closed }), !closed, let begin { closed = true; emit(.finished(begin.identity)) }
    }
    private func failed(_ scope: LiveLaneScope, workID: UUID) {
        if !closed, matchesWork(scope,workID), lanes[scope.source]?.state != .needsReplacement { cut(scope.source,reason: .engineRestart) }
    }
    private func workReturned(_ scope: LiveLaneScope, workID: UUID) {
        guard matchesWork(scope,workID) else { return }
        if let packet = works[scope.source]?.packet {
            do { try lanes[scope.source]?.sharedInput?.recordActualPacketReturn(packet) }
            catch { cut(scope.source,reason: .engineRestart); return }
        }
        works[scope.source] = nil
        if !closed { progress(scope.source); kick(scope.source) }
    }
    private func startRetirement(_ source: LiveSource) {
        guard let lane = lanes[source], !inputRetired(lane), retirements[source] == nil else { return }
        let scope = self.scope(source), id = UUID(), work = works[source], session = lane.session
        let runtime = vadRuntime, nativeScope = lane.nativeScope, configured = begin?.vad != nil
        let noVADInput = lane.admitted == 0 && lane.sharedInput == nil
        let task = Task {
            await self.testingBeforeRetirement(scope)
            await session?.retire()
            // A later source can be unbound while a peer awaits activation.
            // Zero input is already retired; model setup still gates replacement.
            var vadRetired = !configured || ((runtime == nil || nativeScope == nil) && noVADInput)
            if let runtime, let nativeScope {
                do {
                    let seal = try await runtime.retireInput(scope: nativeScope)
                    _ = try await runtime.settleRetirement(seal.receipt)
                    vadRetired = true
                } catch { vadRetired = false }
            }
            if let work { await work.task.value }
            return RetirementResult(vadRetired: vadRetired)
        }
        retirements[source] = .init(scope: scope,id: id,task: task)
        Task { let result = await task.value; self.retirementCompleted(scope,id: id,workID: work?.id,result: result) }
    }
    private func retirementCompleted(_ scope: LiveLaneScope, id: UUID, workID: UUID?, result: RetirementResult) {
        guard matches(scope), retirements[scope.source]?.scope == scope, retirements[scope.source]?.id == id,
              var lane = lanes[scope.source] else { return }
        // This phase awaited actual return too. Clear only its exact record
        // before ACK so immediate Resume cannot race the independent observer.
        if let current = works[scope.source] {
            guard current.id == workID, current.scope == scope else { return }
            if let packet = current.packet {
                do { try lane.sharedInput?.recordActualPacketReturn(packet) } catch { return }
            }
            works[scope.source] = nil
        }
        lane.session = nil; lane.inFlight = 0; lane.processed = lane.consumed; lane.asrInputRetired = true
        lane.vadInputRetired = result.vadRetired
        lanes[scope.source] = lane; retirements[scope.source] = nil
        guard !closed, lane.state != .closed else { return }
        if inputRetired(lane), let pending = lane.barrier, pending.1.kind != .utterance {
            finishBarrier(scope.source,id: pending.0,barrier: pending.1)
        }
        // Closed/retiring progress is suppressed; allocation is never refunded.
        progress(scope.source)
    }

    private func inputRetired(_ lane: Lane) -> Bool {
        lane.asrInputRetired && (begin?.vad == nil || lane.vadInputRetired)
    }
    private func logicalVADSeal(_ source: LiveSource) {
        guard let identity = begin?.vad?.identity, let lane = lanes[source], !lane.vadRetired else { return }
        if var ledger = lane.sharedInput {
            do { try ledger.seal(scope: scope(source)); lanes[source]?.sharedInput = ledger }
            catch { closed = true; emit(.failed(scope(source).identity,.unavailable)); return }
        }
        lanes[source]?.vadRetired = true
        send(source,.vad(.retired(identity: identity,contextID: lane.vadContext,sampleEnd: lane.vadEnd)))
    }

    private func loadedConfigured(_ factory: any NemotronDecoderMaking,runtime: LiveVADModuleRuntime) async {
        guard !closed, let begin else { return }
        vadRuntime = runtime
        for source in begin.epochs.map(\.source) {
            guard !closed, lanes[source] != nil else { return }
            let scope = self.scope(source)
            lanes[source]?.nativeScope = scope
            do {
                if lanes[source]?.state == .loading {
                    lanes[source]?.sharedInput = try .init(scope: scope,configuration: begin.configuration,vadOwnerID: runtime.ownerID)
                    await testingBeforeVADActivation(scope)
                    guard !closed, matches(scope) else { return }
                    let event = try await runtime.activate(scope: scope)
                    guard !closed, matches(scope) else { return }
                    if lanes[source]?.state == .loading {
                        publishVAD(source,event)
                        lanes[source]?.vadActivated = true
                        if case .degraded = event {
                            let seal = try await runtime.retireInput(scope: scope)
                            let proof = try await runtime.settleRetirement(seal.receipt)
                            guard !closed, matches(scope) else { return }
                            if lanes[source]?.state == .loading { try lanes[source]?.sharedInput?.recordFailedVADRetirement(proof) }
                        }
                        lanes[source]?.runtimeSetupPending = false
                    }
                }
                if lanes[source]?.state != .loading {
                    let seal = try await runtime.retireInput(scope: scope)
                    _ = try await runtime.settleRetirement(seal.receipt)
                    guard matches(scope) else { continue }
                    lanes[source]?.vadInputRetired = true; lanes[source]?.runtimeSetupPending = false
                }
            } catch {
                // A source can retire while activate is waiting for the runtime
                // actor. Keep its wire state sealed and settle that exact binding
                // before clearing setup debt; a second cut would reopen recovery.
                if !closed, matches(scope), lanes[source]?.state == .loading { cut(source,reason: .preparation) }
                do {
                    let seal = try await runtime.retireInput(scope: scope)
                    _ = try await runtime.settleRetirement(seal.receipt)
                    guard matches(scope) else { continue }
                    lanes[source]?.vadInputRetired = true; lanes[source]?.runtimeSetupPending = false
                } catch { /* An uncertain native binding must keep setup debt. */ }
            }
        }
        guard !closed else { return }
        self.factory = factory; loading = nil
        for source in lanes.keys where lanes[source]?.state == .loading { kick(source) }
    }
    private func publishVAD(_ source: LiveSource,_ event: LiveVADModuleEvent) {
        guard !closed, let lane = lanes[source], !lane.vadRetired else { return }
        if case .ready(_,let context,_) = event {
            if !lane.vadPreparing { send(source,.vad(.preparing(identity: event.identity))); lanes[source]?.vadPreparing = true }
            lanes[source]?.vadContext = context
        }
        if case .processed(_,_,let end) = event { lanes[source]?.vadEnd = end }
        send(source,.vad(event))
    }
    private func configuredSession(_ source: LiveSource) -> NemotronDecoderSession? {
        if let existing = lanes[source]?.session { return existing }
        guard let factory else { return nil }
        let scope = self.scope(source)
        let (partials,continuation) = AsyncStream<(UUID,String)>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let session = NemotronDecoderSession(factory: factory) { event in
            if case .partial(let generation,let text) = event, text.utf8.count <= 8192 { continuation.yield((generation,text)) }
        }
        lanes[source]?.session = session; lanes[source]?.partialContinuation = continuation
        lanes[source]?.partialTask = Task { for await (generation,text) in partials { self.partial(scope,generation: generation,text: text) } }
        return session
    }
    private func kickConfigured(_ source: LiveSource) {
        guard !closed, works[source] == nil, retirements[source] == nil, installations[source] == nil,
              factory != nil, vadRuntime != nil, let begin, let lane = lanes[source], !lane.runtimeSetupPending,
              lane.state == .loading || lane.state == .active, lane.nativeScope == scope(source),
              let session = configuredSession(source) else { return }
        let scope = self.scope(source), workID = UUID(), config = begin.configuration
        let command = lane.commands.first
        let alreadyFinishedBarrier: Bool
        if case .barrier(_,let barrier) = command { alreadyFinishedBarrier = barrier.sampleEnd == lane.settled }
        else { alreadyFinishedBarrier = false }
        let task: Task<Void,Never>, token: LiveSharedPacketToken?
        if lane.generation == nil && !alreadyFinishedBarrier {
            token = nil
            task = Task {
                do {
                    guard try await self.prepareConfiguredModule(scope,workID: workID) else { return }
                    let native = try NemotronDecoderConfiguration(language: .init(rawValue: config.language.rawValue)!,chunkMs: config.chunkMs)
                    let generation = try await session.prepare(configuration: native,origin: lane.settled)
                    _ = self.ready(scope,workID: workID,generation: generation,origin: lane.settled)
                } catch { self.failed(scope,workID: workID) }
                await self.testingBeforeWorkReturn(scope)
            }
        } else if let command {
            lanes[source]?.commands.removeFirst()
            switch command {
            case .configuredPacket(let original):
                guard let generation = lane.generation else { cut(source,reason: .engineRestart); return }
                do { token = try lanes[source]?.sharedInput?.startPacket(original.receipt,startSample: original.start,sampleCount: original.samples.count) }
                catch { cut(source,reason: .engineRestart); return }
                guard let token else { cut(source,reason: .engineRestart); return }
                lanes[source]?.queued -= Int64(original.samples.count); lanes[source]?.inFlight = Int64(original.samples.count)
                task = Task {
                    defer { withExtendedLifetime(original) {} }
                    await self.runConfiguredPacket(scope,workID: workID,session: session,config: config,generation: generation,original: original,token: token)
                    await self.testingBeforeWorkReturn(scope)
                }
            case .barrier(let id,let barrier):
                token = nil
                task = Task {
                    await self.runConfiguredBarrier(scope,workID: workID,session: session,config: config,id: id,barrier: barrier)
                    await self.testingBeforeWorkReturn(scope)
                }
            case .packet: cut(source,reason: .engineRestart); return
            }
        } else { return }
        works[source] = .init(scope: scope,id: workID,task: task,packet: token)
        progress(source)
        Task { await task.value; self.workReturned(scope,workID: workID) }
    }
    private func currentConfiguredWork(_ scope: LiveLaneScope,workID: UUID) -> Bool {
        !closed && matchesWork(scope,workID) && lanes[scope.source]?.nativeScope == scope &&
            (lanes[scope.source]?.state == .loading || lanes[scope.source]?.state == .active)
    }
    private func prepareConfiguredModule(_ scope: LiveLaneScope,workID: UUID) async throws -> Bool {
        guard currentConfiguredWork(scope,workID: workID), let runtime = vadRuntime else { return false }
        if lanes[scope.source]?.vadActivated == true { return true }
        let event = try await runtime.activate(scope: scope)
        guard currentConfiguredWork(scope,workID: workID) else { return false }
        publishVAD(scope.source,event)
        if case .degraded = event {
            let seal = try await runtime.retireInput(scope: scope)
            let proof = try await runtime.settleRetirement(seal.receipt)
            guard currentConfiguredWork(scope,workID: workID) else { return false }
            try lanes[scope.source]?.sharedInput?.recordFailedVADRetirement(proof)
        }
        lanes[scope.source]?.vadActivated = true; return true
    }
    private func runConfiguredPacket(_ scope: LiveLaneScope,workID: UUID,session: NemotronDecoderSession,
                                     config: LiveASRConfiguration,generation: UUID,original: OriginalPacket,
                                     token: LiveSharedPacketToken) async {
        do {
            guard let runtime = vadRuntime else { throw LiveProtocolError.unavailable }
            var generation: UUID? = generation, cursor = LivePacketSliceCursor(token: token)
            while !cursor.isComplete {
                try Task.checkCancellation()
                guard currentConfiguredWork(scope,workID: workID), let active = generation else { return }
                let vadActive = lanes[scope.source]?.sharedInput?.progress.vadInputActive == true
                let capacity = vadActive ? try await runtime.sliceCapacity(scope: scope) : 3200
                guard currentConfiguredWork(scope,workID: workID) else { return }
                let range = try cursor.nextRange(vadCapacity: capacity)
                let samples = Array(original.samples[Int(range.lowerBound-original.start)..<Int(range.upperBound-original.start)])
                try lanes[scope.source]?.sharedInput?.submitSlice(token,range: range)
                let native = try await session.append(samples: samples,startSample: range.lowerBound)
                guard currentConfiguredWork(scope,workID: workID) else { return }
                let absolute = lanes[scope.source]!.settled.addingReportingOverflow(native.consumedSamples)
                guard !absolute.overflow else { throw LiveProtocolError.outOfOrder }
                try lanes[scope.source]?.sharedInput?.recordASRAppend(token,processedEnd: range.upperBound,consumedEnd: absolute.partialValue)
                guard processed(scope,workID: workID,generation: active,end: range.upperBound,progress: native) else { return }
                if vadActive {
                    let admission = try await runtime.admitSlice(scope: scope,samples: samples,startSample: range.lowerBound)
                    guard currentConfiguredWork(scope,workID: workID) else { return }
                    if case .window(let windowToken) = admission {
                        let result = try await runtime.complete(windowToken)
                        guard currentConfiguredWork(scope,workID: workID) else { return }
                        switch result {
                        case .processed(let event,let decision):
                            try lanes[scope.source]?.sharedInput?.recordVADProcessed(token,sampleEnd: decision.range.end)
                            publishVAD(scope.source,event); progress(scope.source)
                            if let end = decision.flushEnd {
                                let barrier = LiveFinishBarrier(scope: scope,nextPacketSequence: lanes[scope.source]!.nextPacket,sampleEnd: end,kind: .utterance)
                                guard try await configuredFlush(scope,workID: workID,session: session,generation: active,barrier: barrier) else { return }
                                if let pending = lanes[scope.source]?.barrier, pending.1.kind != .utterance,
                                   pending.1.sampleEnd == end, end == original.receipt.sampleEnd {
                                    generation = nil
                                } else { generation = try await configuredPrepareASR(scope,workID: workID,session: session,config: config,origin: end) }
                            }
                        case .degraded(let event,let receipt):
                            publishVAD(scope.source,event)
                            let proof = try await runtime.settleRetirement(receipt)
                            guard currentConfiguredWork(scope,workID: workID) else { return }
                            try lanes[scope.source]?.sharedInput?.recordFailedVADRetirement(proof)
                            progress(scope.source)
                        }
                    }
                }
                try cursor.commit(range)
            }
            guard currentConfiguredWork(scope, workID: workID) else { return }
            // One original packet is already <=3200 samples. VAD fragmentation
            // must not create multiple optional offers in the same mandatory
            // work. Copy only its immutable PCM value, not the packet owner.
            offerDiarization(scope: scope, samples: original.samples, start: original.start)
        } catch { failed(scope,workID: workID) }
    }
    private func configuredPrepareASR(_ scope: LiveLaneScope,workID: UUID,session: NemotronDecoderSession,
                                      config: LiveASRConfiguration,origin: Int64) async throws -> UUID? {
        try Task.checkCancellation()
        guard currentConfiguredWork(scope,workID: workID) else { return nil }
        let native = try NemotronDecoderConfiguration(language: .init(rawValue: config.language.rawValue)!,chunkMs: config.chunkMs)
        let generation = try await session.prepare(configuration: native,origin: origin)
        return ready(scope,workID: workID,generation: generation,origin: origin) ? generation : nil
    }
    private func configuredFlush(_ scope: LiveLaneScope,workID: UUID,session: NemotronDecoderSession,
                                 generation: UUID,barrier: LiveFinishBarrier) async throws -> Bool {
        let result = try await session.finish(replacingDecoder: false)
        guard currentConfiguredWork(scope,workID: workID) else { return false }
        if !result.range.isEmpty { try lanes[scope.source]?.sharedInput?.recordASRFlush(scope: scope,sampleEnd: barrier.sampleEnd) }
        return commit(scope,workID: workID,generation: generation,result: result,barrier: barrier)
    }
    private func runConfiguredBarrier(_ scope: LiveLaneScope,workID: UUID,session: NemotronDecoderSession,
                                      config: LiveASRConfiguration,id: UUID,barrier: LiveFinishBarrier) async {
        do {
            try Task.checkCancellation()
            guard currentConfiguredWork(scope,workID: workID), let lane = lanes[scope.source] else { return }
            if lane.settled != barrier.sampleEnd {
                guard let generation = lane.generation,
                      try await configuredFlush(scope,workID: workID,session: session,generation: generation,barrier: barrier) else { return }
            }
            guard currentConfiguredWork(scope,workID: workID) else { return }
            if barrier.kind != .utterance {
                logicalVADSeal(scope.source); lanes[scope.source]?.state = .retiring
                startRetirement(scope.source); return
            }
            finishBarrier(scope.source,id: id,barrier: barrier)
            if lanes[scope.source]?.generation == nil {
                _ = try await configuredPrepareASR(scope,workID: workID,session: session,config: config,origin: barrier.sampleEnd)
            }
        } catch { failed(scope,workID: workID) }
    }
    private func replaceConfigured(identity: LiveSessionIdentity,oldID: UUID,epoch: LiveEpoch) async -> LiveSessionReply {
        guard !Task.isCancelled, !closed, let begin, begin.identity == identity, let old = lanes[epoch.source], old.epoch.id == oldID else { return .rejected(.staleScope) }
        guard old.state == .needsReplacement || old.state == .paused, inputRetired(old), !old.runtimeSetupPending,
              works[epoch.source] == nil, retirements[epoch.source] == nil, installations[epoch.source] == nil,
              factory != nil, let runtime = vadRuntime, let nativeFrom = old.nativeScope else { return .rejected(.unavailable) }
        guard !knownEpochs.contains(epoch.id), LiveSessionBegin(identity: identity,configuration: begin.configuration,epochs: [epoch],vad: begin.vad).isValid else { return .rejected(.invalidConfiguration) }
        // Retain every burned UUID. Exhaustion cannot mutate a native binding
        // or grow replay history beyond this helper's fixed lifetime budget.
        guard knownEpochs.count < epochLimit else { return .rejected(.unavailable) }
        let wireOld = scope(epoch.source), new = LiveLaneScope(identity: identity,source: epoch.source,epochID: epoch.id)
        let reservation = Installation(id: UUID(),wireOld: wireOld,nativeFrom: nativeFrom,new: new)
        installations[epoch.source] = reservation; knownEpochs.insert(epoch.id)
        var mutated = false
        do {
            await testingBeforeInstall(wireOld,new); try Task.checkCancellation()
            guard !closed, matches(wireOld), installations[epoch.source]?.id == reservation.id,
                  lanes[epoch.source]?.state == .paused || lanes[epoch.source]?.state == .needsReplacement else { throw LiveProtocolError.closed }
            try await runtime.installAfterRetirement(oldScope: nativeFrom,newScope: new); mutated = true
            try Task.checkCancellation()
            await testingAfterInstall(wireOld,new); try Task.checkCancellation()
            guard !closed, matches(wireOld), installations[epoch.source]?.id == reservation.id,
                  lanes[epoch.source]?.state == .paused || lanes[epoch.source]?.state == .needsReplacement else { throw LiveProtocolError.closed }
            var fresh = Lane(epoch: epoch); fresh.nativeScope = new
            fresh.sharedInput = try .init(scope: new,configuration: begin.configuration,vadOwnerID: runtime.ownerID)
            old.partialTask?.cancel(); old.partialContinuation?.finish()
            lanes[epoch.source] = fresh; installations[epoch.source] = nil
            replaceDiarizationEpoch(previous: wireOld, epoch: epoch, paused: old.state == .paused)
            kick(epoch.source)
            return .accepted // No suspension after the final cancellation gate.
        } catch {
            if mutated {
                let abort = Task {
                    do { let seal = try await runtime.retireInput(scope: new); _ = try await runtime.settleRetirement(seal.receipt); return true }
                    catch { return false }
                }
                let settled = await abort.value
                guard matches(wireOld), installations[epoch.source]?.id == reservation.id else { return .rejected(.closed) }
                guard settled else { return .rejected(.unavailable) } // Keep reservation if binding is uncertain.
                lanes[epoch.source]?.nativeScope = new
            }
            if installations[epoch.source]?.id == reservation.id { installations[epoch.source] = nil }
            return .rejected(closed ? .closed : .unavailable)
        }
    }

    var diarizationIsIdle: Bool {
        guard let d = diarization else { return false }
        return d.phase == .retired ? d.joined : (d.phase == .active || d.phase == .awaitingInput) && d.work == nil && d.frames == nil && works[.system] == nil && lanes[.system]?.commands.isEmpty == true
    }
    var diarizationIsPaused: Bool { diarization?.phase == .paused && diarization?.work == nil }

    private func prepareDiarization(scope: LiveLaneScope, owner: UUID, configuration: LiveDiarizationConfiguration, requestID: UUID) -> LiveSessionReply {
        if let current = diarization {
            guard current.phase != .retired else { return .rejected(.closed) }
            return current.requestedScope == scope && current.ownerID == owner && current.configuration == configuration && current.requestID == requestID ? .accepted : .rejected(.closed)
        }
        guard !closed, matches(scope), scope.source == .system else { return .rejected(.staleScope) }
        guard configuration.isValid else { return .rejected(.invalidConfiguration) }
        guard let loader = diarizationLoader, diarizationEmit != nil, let lane = lanes[.system],
              !lane.closing, lane.state == .active || lane.state == .loading else { return .rejected(.unavailable) }
        diarization = .init(ownerID: owner, requestID: requestID, requestedScope: scope, configuration: configuration, scope: scope)
        guard emitDiarization(.preparing, scope: scope) else { retireDiarization(.output); return .accepted }
        let task = Task {
            do { try Task.checkCancellation(); return DiarizationOutcome.loaded(try await loader(configuration)) }
            catch { return DiarizationOutcome.failed } // Cached tasks retain no arbitrary native Error.
        }
        installDiarizationWork(task); return .accepted
    }
    private func installDiarizationWork(_ task: Task<DiarizationOutcome, Never>) {
        let id = UUID(); diarization?.work = .init(id: id, task: task)
        Task { let result = await task.value; diarizationReturned(id, outcome: result) }
    }
    private func emitDiarization(_ payload: LiveDiarizationEvent.Payload, scope: LiveLaneScope) -> Bool {
        guard let current = diarization, current.nextEvent < .max, let emit = diarizationEmit else { return false }
        diarization?.nextEvent += 1
        return emit(.init(scope: scope, ownerID: current.ownerID, sequence: current.nextEvent, payload: payload))
    }
    private func offerDiarization(scope: LiveLaneScope, samples: [Float], start: Int64) {
        guard scope.source == .system, var current = diarization, current.phase != .retired else { return }
        if current.phase == .preparing { return } // Never relabel earlier unavailable PCM.
        guard current.scope == scope, current.phase == .awaitingInput || current.phase == .active,
              current.work == nil, current.frames == nil else { retireDiarization(.capacity); return }
        guard (1...3200).contains(samples.count), samples.allSatisfy(\.isFinite), start >= 0,
              start <= Int64.max - Int64(samples.count), current.streamEnd <= Int64.max - 320 - Int64(samples.count),
              current.streamEnd + Int64(samples.count) - current.frameEnd * 160 <= current.configuration.identity.preset.pendingSampleLimit else { retireDiarization(.capacity); return }
        let end = start + Int64(samples.count)
        let meeting: LiveMeetingRange?
        if let origin = lanes[.system]?.epoch.meetingOriginNanoseconds {
            let lo = start.multipliedReportingOverflow(by: 62_500), hi = end.multipliedReportingOverflow(by: 62_500)
            let a = origin.addingReportingOverflow(lo.partialValue), b = origin.addingReportingOverflow(hi.partialValue)
            guard !lo.overflow, !hi.overflow, !a.overflow, !b.overflow,
                  current.lastMeetingEnd.map({ a.partialValue >= $0 }) ?? true else { retireDiarization(.discontinuity); return }
            meeting = .init(startNanoseconds: a.partialValue, endNanoseconds: b.partialValue)
        } else { meeting = nil }
        let first = current.session == nil
        if first {
            guard let driver = current.driver else { retireDiarization(.failed); return }
            do {
                let session = try LiveDiarizationSession(scope: scope, preset: current.configuration.identity.preset,
                    witness: DiarizationWitness(current.ownerID), sourceOrigin: start) { driver }
                current.session = session; current.contextID = session.contextID; current.phase = .active
                current.ranges[scope.epochID] = .init(start: start, end: start)
            } catch { retireDiarization(.failed); return }
            diarization = current
            guard emitDiarization(.ready(originSample: start, contextID: current.contextID!), scope: scope) else { retireDiarization(.output); return }
            current = diarization!
        }
        guard let session = current.session, var range = current.ranges[scope.epochID], range.end == start else { retireDiarization(.discontinuity); return }
        range.end = end; current.ranges[scope.epochID] = range; current.streamEnd += Int64(samples.count)
        if let meeting { current.lastMeetingEnd = meeting.endNanoseconds }; diarization = current
        // Capture only this bounded slice; no OriginalPacket or mandatory receipt.
        let task = Task {
            do {
                if first { _ = try await session.prepare() }
                let token = try await session.admit(scope: scope, samples: samples, startSample: start, meeting: meeting)
                return DiarizationOutcome.batch(try await session.complete(token), terminal: false)
            } catch { return DiarizationOutcome.failed }
        }
        installDiarizationWork(task)
    }
    private func diarizationReturned(_ id: UUID, outcome: DiarizationOutcome) {
        guard var current = diarization, current.work?.id == id, current.phase != .retired else { return }
        current.work = nil
        switch outcome {
        case .loaded(let driver):
            guard !closed, matches(current.scope), lanes[.system]?.state == .active || lanes[.system]?.state == .loading else { retireDiarization(.discontinuity); return }
            current.driver = .init(driver); current.phase = .awaitingInput
        case .batch(let batch, let terminal):
            guard batch.token.contextID == current.contextID, batch.streamSampleEnd == current.streamEnd,
                  batch.frames.count <= LiveDiarizationTimeline.maximumMappedFrames else { retireDiarization(.failed); return }
            current.frameEnd = batch.nativeFrameEnd; current.terminalProduced = terminal
            if !batch.frames.isEmpty { current.frames = batch.frames; current.frameCursor = 0 }
        case .paused: current.phase = .paused
        case .resumed:
            guard let next = current.resumePending else { retireDiarization(.failed); return }
            current.scope = next.1; current.ranges[next.1.epochID] = .init(start: 0, end: 0)
            current.resumePending = nil; current.phase = .active
        case .failed: retireDiarization(.failed); return
        }
        diarization = current; publishDiarization()
    }
    private func publishDiarization() {
        guard var current = diarization, current.phase != .retired, current.work == nil, current.outstanding == nil else { return }
        if let frames = current.frames {
            guard current.confirmed else { return }
            if current.frameCursor < frames.count {
                let first = frames[current.frameCursor]; var rows: [LiveDiarizationRow] = []
                do {
                    while current.frameCursor < frames.count, rows.count < 2, frames[current.frameCursor].scope == first.scope {
                        let frame = frames[current.frameCursor]
                        guard frame.contextID == current.contextID, first.scope.identity == current.scope.identity, first.scope.source == .system,
                              let admitted = current.ranges[first.scope.epochID], frame.samples.start >= admitted.start, frame.samples.end <= admitted.end else { throw LiveProtocolError.staleScope }
                        rows.append(try .init(streamSamples: frame.streamSamples, samples: frame.samples, meeting: frame.meeting, activity: frame.activity))
                        current.frameCursor += 1
                    }
                } catch { retireDiarization(.failed); return }
                current.outstanding = current.nextEvent; diarization = current
                guard emitDiarization(.posterior(contextID: current.contextID!, rows: rows), scope: first.scope) else { retireDiarization(.output); return }
                return // Exact packet acknowledgement grants the next credit.
            }
            current.frames = nil; current.frameCursor = 0; diarization = current
        }
        advanceDiarizationControl()
    }
    private func orderedDiarizationBarrier(_ barrier: LiveFinishBarrier) {
        guard barrier.scope.source == .system, let current = diarization, current.phase != .retired else { return }
        if barrier.kind == .utterance { return }
        guard current.scope == barrier.scope, current.session != nil,
              current.ranges[barrier.scope.epochID]?.end == barrier.sampleEnd else { retireDiarization(.stopped); return }
        if barrier.kind == .pause { diarization?.pausePending = true; diarization?.phase = .pausing }
        else { diarization?.finishPending = true; diarization?.phase = .finishing }
        advanceDiarizationControl()
    }
    private func replaceDiarizationEpoch(previous: LiveLaneScope, epoch: LiveEpoch, paused: Bool) {
        guard previous.source == .system, let current = diarization, current.phase != .retired else { return }
        guard paused, current.scope == previous, current.resumePending == nil, current.session != nil,
              current.ranges[epoch.id] == nil, current.ranges.count < LiveDiarizationTimeline.maximumEpochs,
              current.phase == .paused || current.phase == .pausing else { retireDiarization(.discontinuity); return }
        diarization?.resumePending = (previous, .init(identity: previous.identity, source: .system, epochID: epoch.id))
        advanceDiarizationControl()
    }
    private func advanceDiarizationControl() {
        guard var current = diarization, current.phase != .retired, current.work == nil, current.frames == nil,
              let session = current.session else { return }
        if current.terminalProduced { retireDiarization(.finished); return }
        let task: Task<DiarizationOutcome, Never>
        if current.pausePending {
            current.pausePending = false; let scope = current.scope
            task = Task { do { _ = try await session.pause(scope: scope); return .paused } catch { return .failed } }
        } else if let resume = current.resumePending, current.phase == .paused {
            task = Task { do { _ = try await session.resume(previous: resume.0, next: resume.1); return .resumed } catch { return .failed } }
        } else if current.finishPending {
            current.finishPending = false; let scope = current.scope
            task = Task { do { return .batch(try await session.finish(scope: scope), terminal: true) } catch { return .failed } }
        } else { return }
        diarization = current; installDiarizationWork(task)
    }
    private func attachingDiarization(_ segment: CommittedLiveSegment, scope: LiveLaneScope) -> CommittedLiveSegment {
        guard let current = diarization, current.phase != .retired, current.confirmed, let context = current.contextID,
              scope.identity == current.scope.identity, scope.source == .system, let samples = segment.range.samples,
              let range = current.ranges[scope.epochID], samples.start >= range.start, samples.end <= range.end else { return segment }
        return .init(id: segment.id, source: segment.source, range: segment.range, text: segment.text,
                     words: segment.words, language: segment.language, diarizerContextID: context)
    }
    private func retireDiarization(_ reason: LiveDiarizationEvent.RetirementReason) {
        guard var current = diarization, current.phase != .retired else { return }
        current.phase = .retired; current.frames = nil; current.outstanding = nil; current.confirmed = false
        current.work?.task.cancel(); diarization = current
        let id = UUID(), work = current.work, session = current.session, driver = current.driver
        let task = Task {
            var returned: (any LiveDiarizationDriving)?
            if let work, case .loaded(let actual) = await work.task.value { returned = actual }
            if let session { await session.retire(); await session.joinRetirement() }
            await driver?.shutdown(); await returned?.shutdown()
            withExtendedLifetime(work) {}; withExtendedLifetime(session) {}; withExtendedLifetime(driver) {}; withExtendedLifetime(returned) {}
        }
        diarizationRetirement = (id, task, reason)
        Task { await task.value; diarizationRetired(id, reason: reason) }
    }
    private func diarizationRetired(_ id: UUID, reason: LiveDiarizationEvent.RetirementReason) {
        guard diarizationRetirement?.0 == id, var current = diarization else { return }
        current.work = nil; current.driver = nil; current.session = nil; current.joined = true
        current.pausePending = false; current.resumePending = nil; current.finishPending = false
        diarization = current; diarizationRetirement = nil
        _ = emitDiarization(.retired(contextID: current.contextID, receiptID: id, reason: reason), scope: current.scope)
    }
    func joinDiarizationRetirement() async {
        if let operation = diarizationRetirement {
            await operation.1.value
            diarizationRetired(operation.0, reason: operation.2)
        } // Exact id makes concurrent join/observer finalization idempotent.
    }
}
