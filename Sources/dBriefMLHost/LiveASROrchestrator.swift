import Foundation
import dBriefWire

/// A dedicated process owns one shared immutable factory and a serial pump per
/// source. Admission never awaits native work; no ordinary backend mutex is used.
actor LiveASROrchestrator {
    typealias Loader = @Sendable (LiveASRConfiguration) async throws -> any NemotronDecoderMaking
    private enum State { case loading, active, paused, needsReplacement, closed }
    private enum Command { case packet([Float], Int64), barrier(UUID, LiveFinishBarrier) }
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
        var partialTask: Task<Void, Never>?
        var partialContinuation: AsyncStream<(UUID, String)>.Continuation?
    }
    private let loader: Loader
    private let emit: @Sendable (LiveSessionEvent) -> Void
    private var begin: LiveSessionBegin?
    private var beginRequestID: UUID?
    private var factory: (any NemotronDecoderMaking)?
    private var loading: Task<Void, Never>?
    private var lanes: [LiveSource: Lane] = [:]
    private var tasks: [LiveSource: Task<Void, Never>] = [:]
    private var knownEpochs: Set<UUID> = []
    private var closed = false

    init(loader: @escaping Loader, emit: @escaping @Sendable (LiveSessionEvent) -> Void) { self.loader = loader; self.emit = emit }

    func handle(_ request: LiveSessionRequest, requestID: UUID) -> LiveSessionReply {
        switch request {
        case .begin(let input):
            if let begin { return begin == input && beginRequestID == requestID ? .accepted : .rejected(.closed) }
            guard !closed, input.isValid else { return .rejected(.invalidConfiguration) }
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
            for source in lanes.keys { cut(source, reason: .stopped); lanes[source]?.state = .closed; send(source, .closed(sampleEnd: lanes[source]!.captured)) }
            closed = true; emit(.finished(identity)); return .accepted
        case .replaceEpoch(let identity, let oldID, let epoch):
            guard !closed, let begin, begin.identity == identity, let old = lanes[epoch.source], old.epoch.id == oldID else { return .rejected(.staleScope) }
            guard old.state == .needsReplacement || old.state == .paused, tasks[epoch.source] == nil, factory != nil else { return .rejected(.unavailable) }
            guard !knownEpochs.contains(epoch.id), LiveSessionBegin(identity: identity, configuration: begin.configuration, epochs: [epoch]).isValid else { return .rejected(.invalidConfiguration) }
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
            lanes[scope.source]?.captured = end; lanes[scope.source]?.nextPacket = nextSequence
            cut(scope.source, reason: reason); return .accepted
        case .barrier(let barrier):
            guard matches(barrier.scope), let lane = lanes[barrier.scope.source] else { return .rejected(.staleScope) }
            if let prior = lane.completedBarrier, prior.0 == requestID, prior.1 == barrier { return .accepted }
            guard !closed else { return .rejected(.closed) }
            if let prior = lane.barrier { return prior.0 == requestID && prior.1 == barrier ? .accepted : .rejected(.outOfOrder) }
            guard barrier.sampleEnd == lane.captured, barrier.nextPacketSequence == lane.nextPacket else { return .rejected(.outOfOrder) }
            if lane.state == .needsReplacement || lane.state == .loading {
                guard barrier.kind != .utterance else { return .rejected(.unavailable) }
                cut(barrier.scope.source, reason: .stopped)
                finishBarrier(barrier.scope.source, id: requestID, barrier: barrier)
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
        for source in lanes.keys { if lanes[source]?.state == .loading { kick(source) } else { send(source, .needsEpochReplacement) } }
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
        guard let lane = lanes[source], let begin else { return }
        let held = max(0, lane.processed - lane.consumed)
        let pending = lane.queued + lane.inFlight + held
        send(source, .progress(.init(capturedSampleEnd: lane.captured, admittedSampleEnd: lane.admitted,
            consumedSampleEnd: lane.consumed, queuedSamples: lane.queued, inFlightSamples: lane.inFlight, heldSamples: held,
            creditSamples: lane.state == .active ? max(0, Int64(begin.configuration.pendingSampleLimit) - pending) : 0)))
    }
    private func cut(_ source: LiveSource, reason: LiveGapReason) {
        guard var lane = lanes[source], lane.state != .closed else { return }
        let first = lane.state != .needsReplacement
        lane.state = .needsReplacement; lane.gapReason = reason; lane.generation = nil
        lane.commands.removeAll(); lane.queued = 0; lane.barrier = nil; lane.closing = false
        lane.partialContinuation?.finish(); lane.partialTask?.cancel()
        let gap = lane.settled..<lane.captured; lane.settled = lane.captured; lanes[source] = lane
        if first {
            tasks[source]?.cancel()
            if let session = lane.session { Task { await session.retire() } }
        }
        if !gap.isEmpty { send(source, .settled(.init(epochID: lane.epoch.id, source: source,
            range: .init(samples: .init(start: gap.lowerBound,end: gap.upperBound), meeting: nil), kind: .gap(reason)))) }
        if first { send(source, .needsEpochReplacement) }
        progress(source)
    }

    private func kick(_ source: LiveSource) {
        guard tasks[source] == nil, let factory, let begin, var lane = lanes[source], lane.state == .active || lane.state == .loading else { return }
        guard lane.generation == nil || !lane.commands.isEmpty else { return }
        let scope = self.scope(source), config = begin.configuration
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
        tasks[source] = Task {
            do {
                var generation = generation
                let configuration = try NemotronDecoderConfiguration(language: .init(rawValue: config.language.rawValue)!, chunkMs: config.chunkMs)
                if generation == nil { generation = try await session.prepare(configuration: configuration, origin: origin)
                    guard self.ready(scope, generation: generation!, origin: origin) else { self.pumpDone(scope); return } }
                while let command = self.next(scope) {
                    try Task.checkCancellation()
                    switch command {
                    case .packet(let samples, let start):
                        let native = try await session.append(samples: samples, startSample: start)
                        guard self.processed(scope, generation: generation!, end: start + Int64(samples.count), progress: native) else { self.pumpDone(scope); return }
                    case .barrier(let id, let barrier):
                        let result = try await session.finish(replacingDecoder: false)
                        guard self.commit(scope, generation: generation!, result: result, barrier: barrier) else { self.pumpDone(scope); return }
                        self.finishBarrier(source,id: id,barrier: barrier)
                        if barrier.kind != .utterance { self.pumpDone(scope); return }
                        generation = try await session.prepare(configuration: configuration, origin: barrier.sampleEnd)
                        guard self.ready(scope, generation: generation!, origin: barrier.sampleEnd) else { self.pumpDone(scope); return }
                    }
                }
            } catch { self.failed(scope) }
            self.pumpDone(scope)
        }
    }
    private func ready(_ scope: LiveLaneScope, generation: UUID, origin: Int64) -> Bool {
        guard !closed, matches(scope), lanes[scope.source]?.state == .loading || lanes[scope.source]?.state == .active else { return false }
        lanes[scope.source]?.state = .active; lanes[scope.source]?.generation = generation
        send(scope.source,.ready(generation: generation,originSample: origin)); progress(scope.source); return true
    }
    private func next(_ scope: LiveLaneScope) -> Command? {
        guard !closed, matches(scope), var lane = lanes[scope.source], lane.state == .active, !lane.commands.isEmpty else { return nil }
        let command = lane.commands.removeFirst()
        if case .packet(let samples, _) = command { lane.queued -= Int64(samples.count); lane.inFlight = Int64(samples.count) }
        lanes[scope.source] = lane; progress(scope.source); return command
    }
    private func processed(_ scope: LiveLaneScope, generation: UUID, end: Int64, progress native: NemotronDecoderProgress) -> Bool {
        guard !closed, matches(scope), var lane = lanes[scope.source], lane.state == .active, lane.generation == generation else { return false }
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
    private func commit(_ scope: LiveLaneScope, generation: UUID, result: NemotronCommittedUtterance, barrier: LiveFinishBarrier) -> Bool {
        guard !closed, matches(scope), var lane = lanes[scope.source], lane.state == .active, lane.generation == generation,
              result.generation == generation, result.range.lowerBound == lane.settled, result.range.upperBound == barrier.sampleEnd,
              lane.processed == barrier.sampleEnd else { return false }
        guard result.output.text.utf8.count <= 8192, lane.nextSegment < .max else { cut(scope.source,reason: .engineRestart); return false }
        let range = LiveEvidenceRange(samples: result.range.isEmpty ? nil : .init(start: result.range.lowerBound,end: result.range.upperBound),meeting: nil)
        var payload: LiveLaneEvent.Payload?
        if !result.range.isEmpty {
            if result.output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                payload = .settled(.init(epochID: scope.epochID,source: scope.source,range: range,kind: .processedSilence))
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
    private func failed(_ scope: LiveLaneScope) { if !closed, matches(scope), lanes[scope.source]?.state != .needsReplacement { cut(scope.source,reason: .engineRestart) } }
    private func pumpDone(_ scope: LiveLaneScope) {
        guard matches(scope), var lane = lanes[scope.source] else { return }
        tasks[scope.source] = nil; lane.inFlight = 0
        if lane.state == .needsReplacement || lane.state == .closed {
            lane.processed = lane.consumed; lane.session = nil
        }
        lanes[scope.source] = lane
        if !closed { progress(scope.source); kick(scope.source) }
    }
}
