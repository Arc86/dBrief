import Foundation
import dBriefWire

struct LiveASRTransport: Sendable {
    var begin: @Sendable (LiveSessionBegin) async throws -> AsyncThrowingStream<LiveSessionEvent, Error>
    var command: @Sendable (LiveSessionRequest) async throws -> LiveSessionReply
    var deadline: @Sendable (Duration) async -> Void
    var shutdown: @Sendable () async -> Void

    static func live(_ connection: MLHostConnection) -> Self {
        .init(begin: { try await connection.beginLive($0) }, command: { try await connection.sendLive($0) },
              deadline: { await connection.armLiveDeadline($0) }, shutdown: { await connection.shutdownLiveAndWaitForExit() })
    }
}

enum LiveCaptureAdmission: Equatable { case scheduled, dropped, rejected }

/// The asynchronous store boundary permits fault injection without suspending
/// capture admission. Ordered disk checkpoints are a separate persistence owner.
struct LiveCaptureStoreAccess: Sendable {
    var admit: @Sendable (LiveTranscriptEvent) async -> LiveStoreAdmission
    static func live(_ store: LiveTranscriptStore) -> Self { .init(admit: { await store.admit($0) }) }
}

/// Capture owns this actor and its transport. All store writes use one serial
/// publisher; native preparation and command tasks are never joined by Stop.
actor LiveCaptureSessionCoordinator {
    private struct Lane {
        var epoch: LiveEpoch
        var captured: Int64 = 0
        var scheduled: Int64 = 0
        var dispatched: Int64 = 0
        var admitted: Int64 = 0
        var consumed: Int64 = 0
        var settled: Int64 = 0
        var nextPacket: UInt64 = 0
        var nextDispatchedPacket: UInt64 = 0
        var nextAcknowledgedPacket: UInt64 = 0
        var nextEvent: UInt64 = 0
        var receipts: [UInt64: Int64] = [:]
        var packets: [LiveAudioPacket] = []
        var ready = false
        var cutReason: LiveGapReason?
        var cutAcknowledgedEnd: Int64 = -1
        var pumping = false
        var finishSent = false
        var closed = false
    }
    private enum Publication {
        case begin(LiveEpoch)
        case event(LiveEpoch, LiveTranscriptEvent.Payload)
        case rawLoss(LiveCaptureRawLoss)
        case clearPartials
        case close
    }
    private struct Replacement {
        let oldEpochID: UUID
        let epoch: LiveEpoch
        var events: [LiveLaneEvent] = []
    }
    private let input: LiveSessionBegin
    private let store: LiveTranscriptStore
    private let storeAccess: LiveCaptureStoreAccess
    private let validity: RecordingDerivativeValidity?
    private let ingress: LiveCaptureIngress?
    private let invalidIngress: Bool
    private let transport: LiveASRTransport
    private let drainDeadline: Duration
    private let preparationDeadline: Duration
    private let resources: LiveModelResourcePolicy?
    private let lease: LiveResourceLease?
    private var lanes: [LiveSource: Lane] = [:]
    private var started = false
    private var closing = false
    private var sealed = false
    private var terminal = false
    private var storeClosed = false
    private var closureFailed = false
    private var beginTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var timerGeneration: UUID?
    private var publications: [Publication] = []
    private var publisher: Task<Void, Never>?
    private var storeSequences: [UUID: UInt64] = [:]
    private var publishedEpochs: [UUID: LiveEpoch] = [:]
    private var replacements: [LiveSource: Replacement] = [:]
    private var knownEpochs: Set<UUID> = []
    private var registeredEpochs: [LiveEpoch] = []
    private var capturedByEpoch: [UUID: Int64] = [:]
    private var closureWaiters: [CheckedContinuation<Void, Error>] = []

    init(input: LiveSessionBegin, store: LiveTranscriptStore, transport: LiveASRTransport,
         drainDeadline: Duration = .seconds(3), preparationDeadline: Duration = .seconds(30),
         resources: LiveModelResourcePolicy? = nil, lease: LiveResourceLease? = nil,
         validity: RecordingDerivativeValidity? = nil,
         ingress: LiveCaptureIngress? = nil,
         storeAccess: LiveCaptureStoreAccess? = nil) {
        self.input = input; self.store = store; self.transport = transport
        self.storeAccess = storeAccess ?? .live(store)
        self.validity = validity
        invalidIngress = ingress.map { !$0.matches(input) } ?? false
        self.ingress = ingress.flatMap { $0.matches(input) ? $0 : nil }
        self.drainDeadline = drainDeadline; self.preparationDeadline = preparationDeadline
        self.resources = resources; self.lease = lease
    }

    var readySources: Set<LiveSource> { Set(lanes.values.filter { $0.ready && $0.cutReason == nil && !$0.closed }.map { $0.epoch.source }) }
    nonisolated func belongs(to identity: LiveSessionIdentity, store: LiveTranscriptStore, validity: RecordingDerivativeValidity) -> Bool {
        input.identity == identity && self.store === store && self.validity === validity
    }
    private var isValidOwner: Bool { validity.map { (try? $0.withValidResult { true }) == true } ?? true }

    func start() throws {
        guard !started, !terminal, isValidOwner, !invalidIngress, input.isValid, store.identity == input.identity,
              lease.map({ $0.identity == input.identity && $0.request.chunkMs == input.configuration.chunkMs &&
                  $0.request.sourceCount == input.epochs.count && input.epochs.allSatisfy { $0.engineRevision == lease?.request.modelRevision } }) ?? true else { throw LiveProtocolError.invalidConfiguration }
        started = true
        for epoch in input.epochs {
            lanes[epoch.source] = Lane(epoch: epoch); knownEpochs.insert(epoch.id)
            registeredEpochs.append(epoch); capturedByEpoch[epoch.id] = 0; publish(.begin(epoch))
        }
        armTimer(preparationDeadline, reason: .preparation)
        let transport = self.transport, input = self.input
        beginTask = Task { [weak self] in
            do { let stream = try await transport.begin(input); await self?.attach(stream) }
            catch { await self?.terminate(.unavailable) }
        }
    }

    /// Only the already registered stream may use closingTail, before its EOF.
    /// Unsent frames and frames awaiting a reply stay charged until consumption.
    func offer(scope: LiveLaneScope, samples: [Float], closingTail: Bool = false,
               reservation: LiveCaptureIngress.NormalizedReservation? = nil) -> LiveCaptureAdmission {
        guard started, !terminal, !sealed, isValidOwner, scope.identity == input.identity,
              var lane = lanes[scope.source], lane.epoch.id == scope.epochID, !lane.closed,
              (!closing || closingTail), (1...3200).contains(samples.count), samples.allSatisfy(\.isFinite) else { return .rejected }
        if let ingress {
            guard let reservation, reservation.owner === ingress, reservation.scope == scope,
                  reservation.contains(samples.count) else { return .rejected }
        } else if reservation != nil { return .rejected }
        let end = lane.captured.addingReportingOverflow(Int64(samples.count))
        guard !end.overflow, evidence(lane.epoch, lane.captured, end.partialValue) != nil else { terminate(.unknownClock); return .rejected }
        lane.captured = end.partialValue; lanes[scope.source] = lane
        capturedByEpoch[lane.epoch.id] = lane.captured
        guard publishProgress(scope.source) else { return .dropped }
        if !lane.ready || lane.cutReason != nil {
            _ = reservation?.discard(samples.count)
            cut(scope.source, reason: lane.cutReason ?? .preparation); return .dropped
        }
        guard lane.captured - lane.consumed <= Int64(input.configuration.pendingSampleLimit),
              lane.packets.count < 64, lane.receipts.count < 128, lane.nextPacket < UInt64.max - 1 else {
            _ = reservation?.discard(samples.count)
            cut(scope.source, reason: .overload); return .dropped
        }
        do {
            let packet = try LiveAudioPacket(scope: scope,sequence: lane.nextPacket,startSample: lane.scheduled,samples: samples)
            if let ingress, let reservation, !ingress.schedule(reservation,start: lane.scheduled,count: samples.count) {
                _ = reservation.discard(samples.count); cut(scope.source,reason: .overload); return .dropped
            }
            lane.nextPacket += 1; lane.scheduled = lane.captured
            lane.packets.append(packet); lane.receipts[packet.sequence] = lane.captured; lanes[scope.source] = lane
            kick(scope.source); return .scheduled
        } catch { _ = reservation?.discard(samples.count); terminate(.unavailable); return .rejected }
    }

    func beginClosing() {
        guard started, !terminal, !closing else { return }
        closing = true; publish(.clearPartials)
        ingress?.closeInput()
    }

    /// Called only after capture streams and converter tails reach EOF. The
    /// independent deadline includes blocked IPC and cancellation-ignoring prep.
    func hardwareDidClose() {
        guard started, !terminal, closing, !sealed else { return }
        for source in lanes.keys { publishIngressLosses(source: source) }
        guard !terminal else { return }
        sealed = true
        armTimer(drainDeadline, reason: .deadline)
        let transport = self.transport, duration = drainDeadline
        Task { await transport.deadline(duration) }
        for source in lanes.keys { kick(source) }
    }

    func waitUntilClosed() async throws {
        if storeClosed { return }
        if closureFailed { throw LiveProtocolError.unavailable }
        guard closureWaiters.count < 16 else { throw LiveProtocolError.outputLimit }
        try await withCheckedThrowingContinuation { closureWaiters.append($0) }
    }

    func synchronizeStore() async { await publisher?.value }
    func recordCaptureLoss(owner: LiveSessionIdentity, loss: LiveCaptureRawLoss) -> Bool {
        guard started, !sealed, !terminal, isValidOwner, owner == input.identity,
              lanes[loss.source] != nil, loss.isValid else { return false }
        return publish(.rawLoss(loss))
    }

    /// Drain the finite raw inbox only after reserving enough ordered outbox
    /// space. On overload terminate drains it through the reserved terminal path.
    func publishIngressLosses(source: LiveSource) {
        guard started, !sealed, !terminal, isValidOwner, lanes[source] != nil, let ingress else { return }
        guard publications.count <= 512 - 128 else { terminate(.overload); return }
        for loss in ingress.takeLosses(source) { _ = publish(.rawLoss(loss)) }
    }
    func retire() { terminate(.stopped) }
    /// Retry only after the control cut is acknowledged. Native retirement may
    /// still return unavailable; neither the store nor epoch advances on denial.
    func replaceEpoch(scope: LiveLaneScope, epoch: LiveEpoch) async throws -> Bool {
        await synchronizeStore()
        guard !closing, !terminal, isValidOwner, scope.identity == input.identity, let lane = lanes[scope.source],
              lane.epoch.id == scope.epochID, lane.cutReason != nil, lane.cutAcknowledgedEnd == lane.captured,
              !lane.pumping, replacements[scope.source] == nil, !knownEpochs.contains(epoch.id),
              epoch.source == scope.source, epoch.language == input.configuration.language.rawValue,
              epoch.engineRevision == lane.epoch.engineRevision, epoch.availability == .active,
              epoch.meetingOriginNanoseconds.map({ $0 >= 0 }) ?? true else { return false }
        replacements[scope.source] = .init(oldEpochID: scope.epochID,epoch: epoch)
        let preflight = await store.checkEpoch(owner: input.identity,epoch: epoch)
        guard preflight == .accepted, !closing, !terminal, isValidOwner else {
            replacements[scope.source] = nil; kick(scope.source); return false
        }
        let reply: LiveSessionReply
        do { reply = try await transport.command(.replaceEpoch(identity: input.identity,oldEpochID: scope.epochID,epoch: epoch)) }
        catch { replacements[scope.source] = nil; terminate(.unavailable); throw error }
        guard !terminal, !closing, isValidOwner, let pending = replacements.removeValue(forKey: scope.source),
              lanes[scope.source]?.epoch.id == pending.oldEpochID else { return false }
        guard reply == .accepted else {
            if !pending.events.isEmpty { terminate(.unavailable) }
            kick(scope.source)
            return false
        }
        if let ingress, !ingress.replaceEpoch(old: scope,new: epoch) { terminate(.unavailable); return false }
        knownEpochs.insert(epoch.id); registeredEpochs.append(epoch); capturedByEpoch[epoch.id] = 0
        lanes[scope.source] = Lane(epoch: epoch)
        guard publish(.begin(epoch)) else { return false }
        // The event stream and reply reader are independent. Hold a fixed small
        // inbox until the accepted replacement has installed its outer epoch.
        for event in pending.events { receive(.lane(event)) }
        return !terminal
    }

    /// Device/stream discontinuity retires only this source's provisional work.
    func recordDiscontinuity(scope: LiveLaneScope, reason: LiveGapReason) {
        guard !closing, !terminal, isValidOwner, scope.identity == input.identity,
              lanes[scope.source]?.epoch.id == scope.epochID else { return }
        cut(scope.source,reason: reason)
    }

    private func attach(_ stream: AsyncThrowingStream<LiveSessionEvent, Error>) {
        guard !terminal else { let transport = self.transport; Task { await transport.shutdown() }; return }
        eventsTask = Task { [weak self] in
            do {
                for try await event in stream { guard let self else { return }; await self.receive(event) }
                await self?.streamEnded()
            } catch { await self?.terminate(.unavailable) }
        }
        // A cut may have happened while begin was suspended.
        for source in lanes.keys { kick(source) }
    }

    private func streamEnded() { if !terminal { terminate(.unavailable) } }

    private func receive(_ event: LiveSessionEvent) {
        guard !terminal else { return }
        guard isValidOwner else { terminate(.stopped); return }
        switch event {
        case .failed(let identity, _): if identity == input.identity { terminate(.unavailable) }
        case .finished(let identity):
            guard identity == input.identity else { return }
            guard sealed, lanes.values.allSatisfy({ $0.closed && $0.settled == $0.captured }) else { terminate(.unavailable); return }
            terminate(nil)
        case .lane(let event):
            guard event.scope.identity == input.identity else { return }
            if var pending = replacements[event.scope.source], pending.epoch.id == event.scope.epochID {
                guard pending.events.count < 16, event.sequence == UInt64(pending.events.count) else { terminate(.unavailable); return }
                pending.events.append(event); replacements[event.scope.source] = pending; return
            }
            guard var lane = lanes[event.scope.source], lane.epoch.id == event.scope.epochID else { return }
            guard event.sequence == lane.nextEvent, event.sequence < .max else { terminate(.unavailable); return }
            lane.nextEvent += 1; lanes[event.scope.source] = lane
            let source = event.scope.source
            switch event.payload {
            case .ready(_, let origin):
                guard origin == lane.settled, !lane.closed else { cut(source,reason: .engineRestart); return }
                if lane.cutReason == nil { lanes[source]?.ready = true }
                if lanes.values.allSatisfy({ $0.ready }) {
                    if !sealed { timer?.cancel(); timerGeneration = nil }
                    if let resources, let lease { Task { await resources.confirmResident(lease) } }
                }
                kick(source)
            case .admitted(let sequence, let end):
                guard lane.cutReason == nil else { return }
                guard sequence == lane.nextAcknowledgedPacket, lane.receipts[sequence] == end, end <= lane.dispatched,
                      end >= lane.admitted else { terminate(.unavailable); return }
                lanes[source]?.nextAcknowledgedPacket += 1; lanes[source]?.receipts[sequence] = nil
                lanes[source]?.admitted = end; publishProgress(source)
            case .progress(let p):
                guard lane.cutReason == nil else { return }
                let pending = p.queuedSamples.addingReportingOverflow(p.inFlightSamples)
                let total = pending.partialValue.addingReportingOverflow(p.heldSamples)
                guard !pending.overflow, !total.overflow, p.queuedSamples >= 0, p.inFlightSamples >= 0, p.heldSamples >= 0,
                      p.capturedSampleEnd >= p.admittedSampleEnd, p.capturedSampleEnd <= lane.dispatched,
                      p.admittedSampleEnd >= lane.admitted, p.admittedSampleEnd <= lane.dispatched,
                      p.consumedSampleEnd >= lane.consumed, p.consumedSampleEnd <= p.admittedSampleEnd,
                      total.partialValue == p.admittedSampleEnd - p.consumedSampleEnd,
                      total.partialValue <= Int64(input.configuration.pendingSampleLimit),
                      p.creditSamples == (lane.closed ? 0 : Int64(input.configuration.pendingSampleLimit) - total.partialValue) else { terminate(.unavailable); return }
                if let ingress, !ingress.consume(scope: event.scope,end: p.consumedSampleEnd) { terminate(.unavailable); return }
                lanes[source]?.admitted = p.admittedSampleEnd; lanes[source]?.consumed = p.consumedSampleEnd
                publishProgress(source)
            case .partial(let partial):
                guard !closing, lane.cutReason == nil else { return }
                guard partial.epochID == lane.epoch.id, partial.source == source, partial.samples.isValid,
                      partial.samples.start >= lane.settled, partial.samples.end <= lane.admitted, partial.text.utf8.count <= 8192 else { terminate(.unavailable); return }
                publish(.event(lane.epoch,.partial(partial)))
            case .committed(let segment):
                guard lane.cutReason == nil else { return }
                guard segment.id.epochID == lane.epoch.id, segment.source == source, segment.isValid,
                      segment.range.meeting == nil, segment.range.savedAudio.isEmpty,
                      let samples = segment.range.samples, samples.start == lane.settled, samples.end <= lane.consumed,
                      let range = evidence(lane.epoch,samples.start,samples.end) else { terminate(.unavailable); return }
                let mapped = CommittedLiveSegment(id: segment.id,source: source,range: range,text: segment.text,
                    words: segment.words,language: segment.language,diarizerContextID: segment.diarizerContextID)
                if publish(.event(lane.epoch,.committed(mapped))) { lanes[source]?.settled = samples.end }
            case .settled(let interval):
                guard lane.cutReason == nil else { return }
                guard interval.epochID == lane.epoch.id, interval.source == source, interval.kind != .committed,
                      interval.committedSegmentID == nil, interval.range.meeting == nil, interval.range.savedAudio.isEmpty,
                      let samples = interval.range.samples, samples.start == lane.settled,
                      samples.end <= (interval.kind == .processedSilence ? lane.consumed : lane.captured),
                      let range = evidence(lane.epoch,samples.start,samples.end) else { terminate(.unavailable); return }
                if publish(.event(lane.epoch,.settled(.init(epochID: lane.epoch.id,source: source,range: range,kind: interval.kind)))) { lanes[source]?.settled = samples.end }
            case .needsEpochReplacement: cut(source,reason: lane.cutReason ?? .engineRestart)
            case .barrierCompleted(_, let kind, let end):
                guard kind == .finish, sealed, lane.finishSent, end == lane.captured else { terminate(.unavailable); return }
            case .closed(let end):
                guard sealed, lane.finishSent, end == lane.captured, lane.settled == lane.captured else { terminate(.unavailable); return }
                lanes[source]?.closed = true; lanes[source]?.ready = false
            }
        }
    }

    private func cut(_ source: LiveSource, reason: LiveGapReason) {
        guard !terminal, var lane = lanes[source], !lane.closed else { return }
        lane.ready = false; lane.cutReason = reason; lane.packets.removeAll(); lane.receipts.removeAll()
        ingress?.discardUndispatched(scope: .init(identity: input.identity,source: source,epochID: lane.epoch.id))
        lanes[source] = lane
        if lane.settled < lane.captured, let range = evidence(lane.epoch,lane.settled,lane.captured) {
            if publish(.event(lane.epoch,.settled(.init(epochID: lane.epoch.id,source: source,range: range,kind: .gap(reason))))) {
                lanes[source]?.settled = lane.captured
            }
        }
        publish(.event(lane.epoch,.availability(.unavailable)))
        kick(source)
    }

    private func kick(_ source: LiveSource) {
        guard !terminal, eventsTask != nil, replacements[source] == nil, let lane = lanes[source], !lane.pumping else { return }
        lanes[source]?.pumping = true
        let transport = self.transport
        Task { [weak self] in
            while let request = await self?.nextCommand(source) {
                do { let reply = try await transport.command(request); await self?.commandCompleted(source,request,reply) }
                catch { await self?.terminate(.unavailable) }
            }
        }
    }

    private func nextCommand(_ source: LiveSource) -> LiveSessionRequest? {
        guard isValidOwner else { terminate(.stopped); return nil }
        guard !terminal, var lane = lanes[source], !lane.closed else { return nil }
        let scope = LiveLaneScope(identity: input.identity,source: source,epochID: lane.epoch.id)
        if let reason = lane.cutReason, lane.cutAcknowledgedEnd < lane.captured {
            return .cut(scope: scope,nextPacketSequence: lane.nextDispatchedPacket,sampleEnd: lane.captured,reason: reason)
        }
        if !lane.packets.isEmpty {
            let packet = lane.packets.removeFirst(); lane.dispatched = packet.startSample + Int64(packet.sampleCount)
            if let ingress, !ingress.markDispatched(scope: scope,end: lane.dispatched) { terminate(.unavailable); return nil }
            lane.nextDispatchedPacket = packet.sequence + 1; lanes[source] = lane; return .packet(packet)
        }
        if sealed && !lane.finishSent {
            lanes[source]?.finishSent = true
            return .barrier(.init(scope: scope,nextPacketSequence: lane.nextDispatchedPacket,sampleEnd: lane.captured,kind: .finish))
        }
        lanes[source]?.pumping = false; return nil
    }

    private func commandCompleted(_ source: LiveSource, _ request: LiveSessionRequest, _ reply: LiveSessionReply) {
        guard !terminal else { return }
        if reply != .accepted {
            // A rejected packet has still advanced the helper capture frontier;
            // a control cut is ordered after it and preserves the exact prefix.
            if case .packet = request { cut(source,reason: .unavailable) }
            else { terminate(.unavailable) }
            return
        }
        if case .cut(_, _, let end, _) = request { lanes[source]?.cutAcknowledgedEnd = end }
    }

    private func armTimer(_ duration: Duration, reason: LiveGapReason) {
        timer?.cancel()
        let generation = UUID(); timerGeneration = generation
        timer = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            await self?.deadlineExpired(generation,reason: reason)
        }
    }

    private func deadlineExpired(_ generation: UUID, reason: LiveGapReason) {
        guard timerGeneration == generation else { return }
        terminate(reason)
    }

    private func terminate(_ reason: LiveGapReason?) {
        guard !terminal else { return }
        terminal = true; closing = true; sealed = true
        ingress?.retireInput()
        replacements.removeAll()
        timer?.cancel(); timerGeneration = nil; beginTask?.cancel(); eventsTask?.cancel()
        for source in lanes.keys {
            guard let lane = lanes[source] else { continue }
            lanes[source]?.packets.removeAll(); lanes[source]?.receipts.removeAll(); lanes[source]?.ready = false
            // At most three terminal publications per source beyond the fixed
            // normal inbox. Never discard an already queued evidence commit.
            publications.append(.event(lane.epoch,.progress(.init(capturedSampleEnd: lane.captured,admittedSampleEnd: lane.admitted,consumedSampleEnd: lane.consumed))))
            if lane.settled < lane.captured, let range = evidence(lane.epoch,lane.settled,lane.captured) {
                publications.append(.event(lane.epoch,.settled(.init(epochID: lane.epoch.id,source: source,range: range,kind: .gap(reason ?? .unavailable)))))
                lanes[source]?.settled = lane.captured
            }
            publications.append(.event(lane.epoch,.availability(.unavailable)))
        }
        // At most 128 raw facts per registered source, separate from normalized
        // terminal settlement. Keep unknown loss even when the normal inbox fills.
        for source in lanes.keys {
            for loss in ingress?.takeLosses(source) ?? [] { publications.append(.rawLoss(loss)) }
        }
        publications.append(.close); startPublisher()
        let transport = self.transport, resources = self.resources, lease = self.lease, ingress = self.ingress
        Task {
            await transport.shutdown(); ingress?.confirmNativeRetired()
            if let resources, let lease { await resources.release(lease) }
        }
    }

    @discardableResult private func publishProgress(_ source: LiveSource) -> Bool {
        guard let lane = lanes[source] else { return false }
        return publish(.event(lane.epoch,.progress(.init(capturedSampleEnd: lane.captured,admittedSampleEnd: lane.admitted,consumedSampleEnd: lane.consumed))))
    }

    @discardableResult private func publish(_ item: Publication) -> Bool {
        guard !terminal else { return false }
        // Coalesce telemetry/preview only; evidence and boundaries retain order.
        if case .event(let epoch, .progress(let p)) = item, case .event(let prior, .progress) = publications.last, epoch == prior {
            publications[publications.count-1] = .event(epoch,.progress(p)); return true
        }
        guard publications.count < 512 else { terminate(.overload); return false }
        publications.append(item); startPublisher(); return true
    }

    private func startPublisher() {
        guard publisher == nil else { return }
        publisher = Task { await self.publishStore() }
    }

    private func publishStore() async {
        while !publications.isEmpty {
            let item = publications.removeFirst()
            var result: LiveStoreAdmission
            switch item {
            case .begin(let epoch):
                var acceptedEpoch = epoch
                result = await store.beginEpoch(owner: input.identity,epoch: epoch)
                if result == .rejected(.invalidRange), !input.epochs.contains(where: { $0.id == epoch.id }) {
                    // Capture or another qualified lane can move the frontier
                    // while native acknowledges. Only this clock loses its
                    // qualification; retain source-local ASR and the other lane.
                    acceptedEpoch = .init(id: epoch.id,source: epoch.source,engineRevision: epoch.engineRevision,
                        language: epoch.language,meetingOriginNanoseconds: nil,availability: epoch.availability)
                    result = await store.beginEpoch(owner: input.identity,epoch: acceptedEpoch)
                    if lanes[epoch.source]?.epoch.id == epoch.id { lanes[epoch.source]?.epoch = acceptedEpoch }
                }
                if result == .accepted || result == .duplicate { publishedEpochs[epoch.id] = acceptedEpoch; storeSequences[epoch.id] = 0 }
            case .event(let epoch, let payload):
                let sequence = storeSequences[epoch.id] ?? 0
                let acceptedEpoch = publishedEpochs[epoch.id] ?? epoch
                guard let mapped = mapPublication(payload,in: acceptedEpoch) else {
                    terminate(.unavailable); await closeActualStore(); publisher = nil; return
                }
                result = await storeAccess.admit(.init(identity: input.identity,epochID: epoch.id,source: epoch.source,sequence: sequence,payload: mapped))
                if result == .accepted || result == .duplicate { storeSequences[epoch.id] = sequence + 1 }
            case .clearPartials: result = await store.clearPartials(owner: input.identity)
            case .rawLoss(let loss): result = await store.recordCaptureLoss(owner: input.identity,loss: loss)
            case .close: result = await store.close(owner: input.identity)
            }
            if case .rejected = result {
                terminate(.unavailable)
                // Recover from a failed publication using the store's actual
                // frontier rather than advancing from an unaccepted commit.
                await closeActualStore()
                break
            }
            if case .close = item { finishWaiters() }
        }
        publisher = nil
    }

    private func mapPublication(_ payload: LiveTranscriptEvent.Payload, in epoch: LiveEpoch) -> LiveTranscriptEvent.Payload? {
        switch payload {
        case .committed(let segment):
            guard let samples = segment.range.samples, let range = evidence(epoch,samples.start,samples.end) else { return nil }
            return .committed(.init(id: segment.id,source: segment.source,range: range,text: segment.text,
                words: segment.words,language: segment.language,diarizerContextID: segment.diarizerContextID))
        case .settled(let interval):
            guard let samples = interval.range.samples, let range = evidence(epoch,samples.start,samples.end) else { return nil }
            return .settled(.init(epochID: interval.epochID,source: interval.source,range: range,kind: interval.kind,committedSegmentID: interval.committedSegmentID))
        case .progress, .partial, .availability: return payload
        }
    }

    private func closeActualStore() async {
        let rawLosses = publications.compactMap { item -> LiveCaptureRawLoss? in
            if case .rawLoss(let loss) = item { return loss }; return nil
        }
        publications.removeAll()
        let projection = await store.projection()
        var recoverySucceeded = true
        for loss in rawLosses {
            let result = await store.recordCaptureLoss(owner: input.identity,loss: loss)
            if result != .accepted && result != .duplicate { recoverySucceeded = false }
        }
        for source in input.epochs.map(\.source) {
            let observed = registeredEpochs.filter { $0.source == source }
            let actual = projection.lanes.first { $0.epoch.source == source }
            let index = actual.flatMap { lane in observed.firstIndex { $0.id == lane.epoch.id } } ?? 0
            for candidate in observed.dropFirst(index) {
                var epoch = candidate
                let existing = actual?.epoch.id == epoch.id ? actual : nil
                if let existing { epoch = existing.epoch }
                else {
                    var result = await store.beginEpoch(owner: input.identity,epoch: epoch)
                    if result == .rejected(.invalidRange) {
                        // An unaccepted clock anchor cannot establish chronology.
                        // Preserve this source's captured samples as unaligned gaps.
                        epoch = .init(id: epoch.id,source: source,engineRevision: epoch.engineRevision,language: epoch.language,
                            meetingOriginNanoseconds: nil,availability: .unavailable)
                        result = await store.beginEpoch(owner: input.identity,epoch: epoch)
                    }
                    guard result == .accepted || result == .duplicate else { recoverySucceeded = false; break }
                    storeSequences[epoch.id] = 0
                }
                let captured = max(existing?.progress.capturedSampleEnd ?? 0,capturedByEpoch[epoch.id] ?? 0)
                var sequence = storeSequences[epoch.id] ?? 0
                let progress = LiveLaneProgress(capturedSampleEnd: captured,
                    admittedSampleEnd: existing?.progress.admittedSampleEnd ?? 0,consumedSampleEnd: existing?.progress.consumedSampleEnd ?? 0)
                let advanced = await store.admit(.init(identity: input.identity,epochID: epoch.id,source: source,sequence: sequence,payload: .progress(progress)))
                guard advanced == .accepted || advanced == .duplicate else { recoverySucceeded = false; break }
                sequence += 1
                if let range = evidence(epoch,existing?.settledSampleEnd ?? 0,captured) {
                    let settled = await store.admit(.init(identity: input.identity,epochID: epoch.id,source: source,sequence: sequence,
                        payload: .settled(.init(epochID: epoch.id,source: source,range: range,kind: .gap(.unavailable)))))
                    guard settled == .accepted || settled == .duplicate else { recoverySucceeded = false; break }
                    sequence += 1
                }
                storeSequences[epoch.id] = sequence
            }
        }
        let result = await store.close(owner: input.identity)
        if recoverySucceeded && (result == .accepted || result == .duplicate) { finishWaiters() }
        else {
            closureFailed = true
            let waiters = closureWaiters; closureWaiters.removeAll()
            for waiter in waiters { waiter.resume(throwing: LiveProtocolError.unavailable) }
        }
    }

    private func finishWaiters() {
        storeClosed = true
        let waiters = closureWaiters; closureWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// An origin comes only from a qualified normalized capture clock. Without
    /// it, evidence remains source-local. Saved AAC/master mapping stays unknown.
    private func evidence(_ epoch: LiveEpoch, _ start: Int64, _ end: Int64) -> LiveEvidenceRange? {
        guard start >= 0, end > start else { return nil }
        var meeting: LiveMeetingRange?
        if let origin = epoch.meetingOriginNanoseconds {
            let a = start.multipliedReportingOverflow(by: 62500), b = end.multipliedReportingOverflow(by: 62500)
            let first = origin.addingReportingOverflow(a.partialValue), last = origin.addingReportingOverflow(b.partialValue)
            guard !a.overflow, !b.overflow, !first.overflow, !last.overflow else { return nil }
            meeting = .init(startNanoseconds: first.partialValue,endNanoseconds: last.partialValue)
        }
        return .init(samples: .init(start: start,end: end),meeting: meeting)
    }
}
