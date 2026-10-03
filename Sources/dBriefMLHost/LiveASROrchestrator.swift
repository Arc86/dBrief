import Foundation
import dBriefWire

/// A dedicated process owns one shared immutable factory and a serial pump per
/// source. Admission never awaits native work; no ordinary backend mutex is used.
actor LiveASROrchestrator {
    typealias Loader = @Sendable (LiveASRConfiguration) async throws -> any NemotronDecoderMaking
    private enum State { case loading, active, retiring, paused, needsReplacement, closed }
    private enum Command { case packet([Float], Int64), barrier(UUID, LiveFinishBarrier) }
    private struct Work: Sendable { let scope: LiveLaneScope; let id: UUID; let task: Task<Void, Never> }
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
        var partialTask: Task<Void, Never>?
        var partialContinuation: AsyncStream<(UUID, String)>.Continuation?
    }
    private let loader: Loader
    private let emit: @Sendable (LiveSessionEvent) -> Void
    private let testingBeforeRetirement: @Sendable (LiveLaneScope) async -> Void
    private let testingBeforeWorkReturn: @Sendable (LiveLaneScope) async -> Void
    private var begin: LiveSessionBegin?
    private var beginRequestID: UUID?
    private var factory: (any NemotronDecoderMaking)?
    private var loading: Task<Void, Never>?
    private var lanes: [LiveSource: Lane] = [:]
    private var works: [LiveSource: Work] = [:]
    private var retirements: [LiveSource: Work] = [:]
    private var knownEpochs: Set<UUID> = []
    private var closed = false

    init(loader: @escaping Loader, emit: @escaping @Sendable (LiveSessionEvent) -> Void,
         testingBeforeRetirement: @escaping @Sendable (LiveLaneScope) async -> Void = { _ in },
         testingBeforeWorkReturn: @escaping @Sendable (LiveLaneScope) async -> Void = { _ in }) {
        self.loader = loader; self.emit = emit
        self.testingBeforeRetirement = testingBeforeRetirement; self.testingBeforeWorkReturn = testingBeforeWorkReturn
    }

    func handle(_ request: LiveSessionRequest, requestID: UUID) -> LiveSessionReply {
        switch request {
        case .begin(let input):
            if let begin { return begin == input && beginRequestID == requestID ? .accepted : .rejected(.closed) }
            guard !closed, input.isValid else { return .rejected(.invalidConfiguration) }
            // Until a real VAD input consumer exists, configuration cannot be
            // silently downgraded to ASR-only readiness or start its loader.
            guard input.vad == nil else { return .rejected(.unavailable) }
            begin = input; beginRequestID = requestID
            for epoch in input.epochs { lanes[epoch.source] = Lane(epoch: epoch); knownEpochs.insert(epoch.id) }
            loading = Task {
                do { let factory = try await loader(input.configuration); self.loaded(factory) }
                catch { self.loadFailed() }
            }
            return .accepted
        case .cancel(let identity):
            guard begin?.identity == identity else { return .rejected(.staleScope) }
            if closed { return .accepted }
            loading?.cancel()
            for source in lanes.keys where lanes[source]?.state != .closed {
                cut(source, reason: .stopped); lanes[source]?.state = .closed
                send(source, .closed(sampleEnd: lanes[source]!.captured))
            }
            closed = true; emit(.finished(identity)); return .accepted
        case .replaceEpoch(let identity, let oldID, let epoch):
            guard !closed, let begin, begin.identity == identity, let old = lanes[epoch.source], old.epoch.id == oldID else { return .rejected(.staleScope) }
            guard old.state == .needsReplacement || old.state == .paused, old.asrInputRetired,
                  works[epoch.source] == nil, retirements[epoch.source] == nil, factory != nil else { return .rejected(.unavailable) }
            guard !knownEpochs.contains(epoch.id), LiveSessionBegin(identity: identity, configuration: begin.configuration, epochs: [epoch],vad: begin.vad).isValid else { return .rejected(.invalidConfiguration) }
            old.partialTask?.cancel(); old.partialContinuation?.finish()
            knownEpochs.insert(epoch.id); lanes[epoch.source] = Lane(epoch: epoch); kick(epoch.source)
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
            guard current.admitted - current.consumed + Int64(samples.count) <= Int64(begin!.configuration.pendingSampleLimit),
                  current.commands.count < 64 else { cut(source, reason: .overload); return .rejected(.unavailable) }
            lanes[source]?.admitted = end; lanes[source]?.queued += Int64(samples.count)
            lanes[source]?.commands.append(.packet(samples, packet.startSample))
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
                guard barrier.kind == .finish, lane.settled == lane.captured, lane.asrInputRetired else { return .rejected(.closed) }
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
                if lanes[barrier.scope.source]?.asrInputRetired == true {
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
        let held = max(0, lane.processed - lane.consumed)
        let pending = lane.queued + lane.inFlight + held
        send(source, .progress(.init(capturedSampleEnd: lane.captured, admittedSampleEnd: lane.admitted,
            consumedSampleEnd: lane.consumed, queuedSamples: lane.queued, inFlightSamples: lane.inFlight, heldSamples: held,
            creditSamples: lane.state == .active ? max(0, Int64(begin.configuration.pendingSampleLimit) - pending) : 0,
            asrConsumedSampleEnd: lane.consumed)))
    }
    private func cut(_ source: LiveSource, reason: LiveGapReason) {
        guard var lane = lanes[source], lane.state != .closed else { return }
        let first = lane.state != .needsReplacement
        lane.state = .needsReplacement; lane.gapReason = reason; lane.generation = nil
        lane.commands.removeAll(); lane.queued = 0
        if lane.barrier?.1.kind == .utterance { lane.barrier = nil }
        lane.closing = lane.barrier != nil
        lane.partialContinuation?.finish(); lane.partialTask?.cancel()
        let gap = lane.settled..<lane.captured; lane.settled = lane.captured; lanes[source] = lane
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
                case .packet(let samples, let start):
                    let native = try await session.append(samples: samples, startSample: start)
                    guard self.processed(scope, workID: workID, generation: generation!, end: start + Int64(samples.count), progress: native) else { return }
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
        guard !closed, matches(scope), var lane = lanes[scope.source], lane.state == .active, lane.generation == generation,
              lane.partialRevision < .max, lane.processed + lane.inFlight > lane.settled else { return }
        lane.partialRevision += 1; lanes[scope.source] = lane
        send(scope.source,.partial(.init(epochID: scope.epochID,source: scope.source,revision: lane.partialRevision,
            samples: .init(start: lane.settled,end: lane.processed + lane.inFlight),text: text)))
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
                payload = .committed(value); lane.nextSegment += 1
            }
        }
        lane.settled = barrier.sampleEnd; lane.consumed = barrier.sampleEnd; lane.generation = nil
        lanes[scope.source] = lane
        progress(scope.source) // Successful flush releases the held tail before settlement.
        if let payload { send(scope.source,payload) }
        return true
    }
    private func finishBarrier(_ source: LiveSource, id: UUID, barrier: LiveFinishBarrier) {
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
        works[scope.source] = nil
        if !closed { progress(scope.source); kick(scope.source) }
    }
    private func startRetirement(_ source: LiveSource) {
        guard let lane = lanes[source], !lane.asrInputRetired, retirements[source] == nil else { return }
        let scope = self.scope(source), id = UUID(), work = works[source], session = lane.session
        let task = Task {
            await self.testingBeforeRetirement(scope)
            await session?.retire()
            if let work { await work.task.value }
            self.retirementCompleted(scope,id: id,workID: work?.id)
        }
        retirements[source] = .init(scope: scope,id: id,task: task)
    }
    private func retirementCompleted(_ scope: LiveLaneScope, id: UUID, workID: UUID?) {
        guard matches(scope), retirements[scope.source]?.scope == scope, retirements[scope.source]?.id == id,
              var lane = lanes[scope.source] else { return }
        // This phase awaited actual return too. Clear only its exact record
        // before ACK so immediate Resume cannot race the independent observer.
        if let current = works[scope.source] {
            guard current.id == workID, current.scope == scope else { return }
            works[scope.source] = nil
        }
        lane.session = nil; lane.inFlight = 0; lane.processed = lane.consumed; lane.asrInputRetired = true
        lanes[scope.source] = lane; retirements[scope.source] = nil
        guard !closed, lane.state != .closed else { return }
        if let pending = lane.barrier, pending.1.kind != .utterance {
            finishBarrier(scope.source,id: pending.0,barrier: pending.1)
        }
        // Closed/retiring progress is suppressed; allocation is never refunded.
        progress(scope.source)
    }
}
