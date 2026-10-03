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
    var checkEpoch: (@Sendable (LiveSessionIdentity, LiveEpoch) async -> LiveStoreAdmission)? = nil
    static func live(_ store: LiveTranscriptStore) -> Self { .init(admit: { await store.admit($0) }) }
}

/// Capture owns this actor and its transport. All store writes use one serial
/// publisher; native preparation and command tasks are never joined by Stop.
actor LiveCaptureSessionCoordinator {
    /// Proposed maximum is a deterministic normalized-sample policy; native
    /// latency/quality qualification is separate from this scheduling bound.
    static let maximumUtteranceSamples: Int64 = 240_000
    struct StreamState: Sendable {
        let epoch: LiveEpoch
        let scope: LiveLaneScope
        let ready: Bool
        let gapReason: LiveGapReason?
        let paused: Bool
        let replacementReady: Bool
    }
    private struct Lane {
        var epoch: LiveEpoch
        var captured: Int64 = 0
        var scheduled: Int64 = 0
        var dispatched: Int64 = 0
        var admitted: Int64 = 0
        /// Only original dispatched packet acknowledgments advance this
        /// module bound. Ordinary progress is a separate accounting fact.
        var moduleAdmittedEnd: Int64 = 0
        var nextModuleAcknowledgment: UInt64 = 0
        /// Only dispatched receipts survive a local cut. This bounded debt is
        /// independent of the ordinary receipt map cleared by that cut.
        var moduleReceipts: [UInt64: Int64] = [:]
        var consumed: Int64 = 0
        var asrConsumed: Int64 = 0
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
        var utteranceBoundary: LiveFinishBarrier?
        var utteranceBoundarySent = false
        var utteranceOrigin: Int64 = 0
        var pauseBoundary: LiveFinishBarrier?
        var pauseBoundarySent = false
        var paused = false
        var closed = false
        var controlID = UUID()
    }
    private enum Publication {
        case begin(LiveEpoch)
        case event(LiveEpoch, LiveTranscriptEvent.Payload)
        case rawLoss(LiveCaptureRawLoss)
        case clearPartials(LiveSource?)
        case close
    }
    private struct PendingPublication {
        let value: Publication
        let bytes: Int
    }
    private struct Replacement {
        let attemptID: UUID
        let oldScope: LiveLaneScope
        let controlID: UUID
        let epoch: LiveEpoch
        var events: [LiveLaneEvent] = []
        var bytes = 0
        var oldEpochID: UUID { oldScope.epochID }
    }
    private struct ReplacementCapacity {
        let attemptID: UUID
        let oldScope: LiveLaneScope
        let proposedID: UUID
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
    private let deadlineSleep: @Sendable (Duration) async throws -> Void
    private let resources: LiveModelResourcePolicy?
    private var lease: LiveResourceLease?
    private let preparation: LiveCaptureStartPreparation?
    private let preparationOwner: UUID
    private let invalidOwnerBinding: Bool
    private let epochHistoryLimit: Int
    private let publicationByteLimit: Int?
    private(set) var pendingPublicationBytes = 0
    private var lanes: [LiveSource: Lane] = [:]
    private var moduleLedger: LiveVADModuleLedger?
    private var started = false
    private var closing = false
    private var sealed = false
    private var terminal = false
    private var storeClosed = false
    private var closureFailed = false
    private var beginTask: Task<Void, Never>?
    private var nativeBeginRequested = false
    private var nativeOwnership: LiveNativeSessionOwnership?
    private var eventsTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var timerGeneration: UUID?
    private var publications: [PendingPublication] = []
    private var publisher: Task<Void, Never>?
    private var storeSequences: [UUID: UInt64] = [:]
    private var publishedEpochs: [UUID: LiveEpoch] = [:]
    private var replacements: [LiveSource: Replacement] = [:]
    /// An abandoned operational inbox cannot release an unresolved command.
    /// Accepted identities transfer permanently into knownEpochs on reply.
    private var replacementCapacity: [LiveSource: ReplacementCapacity] = [:]
    private var helperExited = false
    private var abandonedSources: Set<LiveSource> = []
    private var knownEpochs: Set<UUID> = []
    private var registeredEpochs: [LiveEpoch] = []
    private var capturedByEpoch: [UUID: Int64] = [:]
    private var closureWaiters: [CheckedContinuation<Void, Error>] = []

    init(input: LiveSessionBegin, store: LiveTranscriptStore, transport: LiveASRTransport,
         drainDeadline: Duration = .seconds(3), preparationDeadline: Duration = .seconds(30),
         resources: LiveModelResourcePolicy? = nil, lease: LiveResourceLease? = nil,
         validity: RecordingDerivativeValidity? = nil,
         ingress: LiveCaptureIngress? = nil,
         storeAccess: LiveCaptureStoreAccess? = nil, epochHistoryLimit: Int = 4096, publicationByteLimit: Int? = nil,
         preparation: LiveCaptureStartPreparation? = nil,
         deadlineSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.input = input; self.store = store; self.transport = transport
        self.storeAccess = storeAccess ?? .live(store)
        self.validity = validity
        let preparationOwner = UUID()
        self.preparationOwner = preparationOwner
        invalidIngress = ingress.map { !$0.matches(input) } ?? false
        let preparationMatches = (input.configuration.identity == nil || preparation != nil) && (preparation.map {
            $0.input == input && $0.ingress === ingress && (resources == nil || $0.resources === resources) &&
                lease == nil
        } ?? true)
        let boundIngress = ingress.flatMap { $0.matches(input) ? $0 : nil }
        let ownsCapture = preparationMatches && store.identity == input.identity && store.bindCaptureOwner(preparationOwner) {
            guard preparation?.bind(to: preparationOwner) ?? true else { return false }
            return boundIngress?.bindCoreOwner(preparationOwner) ?? true
        }
        invalidOwnerBinding = !ownsCapture
        self.preparation = ownsCapture ? preparation : nil
        self.ingress = ownsCapture ? boundIngress : nil
        self.drainDeadline = drainDeadline; self.preparationDeadline = preparationDeadline
        self.deadlineSleep = deadlineSleep
        self.resources = resources ?? preparation?.resources; self.lease = ownsCapture ? lease : nil
        self.epochHistoryLimit = min(4096,max(1,epochHistoryLimit))
        self.publicationByteLimit = publicationByteLimit.map { min(2 * 1_024 * 1_024, max(1, $0)) }
        moduleLedger = input.vad.flatMap { _ in try? LiveVADModuleLedger(input: input) }
    }

    deinit {
        timer?.cancel(); eventsTask?.cancel(); beginTask?.cancel()
        nativeOwnership?.shutdown(ownerLost: true)
    }

    var readySources: Set<LiveSource> { Set(lanes.values.filter { $0.ready && $0.cutReason == nil && !$0.closed && !$0.paused && $0.pauseBoundary == nil }.map { $0.epoch.source }) }
    var pausedSources: Set<LiveSource> { Set(lanes.values.filter { $0.paused && !$0.closed }.map { $0.epoch.source }) }
    /// The consumer has sent every frozen raw reservation and real converter
    /// EOF output. Native settlement is ordered behind the captured frontier.
    func requestPauseBoundary(scope: LiveLaneScope, boundary: LiveCaptureIngress.PauseBoundary? = nil) -> Bool {
        guard scope.identity == input.identity, lanes[scope.source]?.epoch.id == scope.epochID else { return false }
        observeIngressLoss(source: scope.source)
        guard started, !closing, !terminal, !sealed, isValidOwner, scope.identity == input.identity,
              let lane = lanes[scope.source], lane.epoch.id == scope.epochID,
              lane.cutReason == nil, !lane.closed, !abandonedSources.contains(scope.source) else { return false }
        if let ingress {
            guard let boundary, ingress.canSealPause(boundary,scope: scope) else { return false }
        } else if boundary != nil { return false }
        if lane.paused || lane.pauseBoundary != nil { return true }
        guard lane.ready else { return false }
        lanes[scope.source]?.pauseBoundary = .init(scope: scope,nextPacketSequence: lane.nextPacket,sampleEnd: lane.captured,kind: .pause)
        publish(.clearPartials(scope.source)); kick(scope.source); return true
    }
    nonisolated func matches(input: LiveSessionBegin, ingress: LiveCaptureIngress) -> Bool {
        self.input == input && self.ingress === ingress && !invalidIngress
    }
    func streamState(source: LiveSource) -> StreamState? {
        guard started, !sealed, !terminal, isValidOwner, let current = lanes[source], !current.closed else { return nil }
        observeIngressLoss(source: source)
        guard !terminal, let lane = lanes[source] else { return nil }
        return .init(epoch: lane.epoch,scope: .init(identity: input.identity,source: source,epochID: lane.epoch.id),
            ready: lane.ready && lane.cutReason == nil && !lane.paused && lane.pauseBoundary == nil,
            gapReason: lane.cutReason ?? (lane.ready || lane.paused ? nil : .preparation),paused: lane.paused || lane.pauseBoundary != nil,
            replacementReady: !lane.pumping && replacements[source] == nil && replacementCapacity[source] == nil && lane.pauseBoundary == nil && moduleRetired(source) &&
                (lane.paused && lane.settled == lane.captured || lane.cutReason != nil && lane.cutAcknowledgedEnd == lane.captured))
    }
    func abandonSource(scope: LiveLaneScope) {
        guard !terminal, isValidOwner, scope.identity == input.identity, lanes[scope.source]?.epoch.id == scope.epochID else { return }
        removeReplacement(scope.source)
        cut(scope.source,reason: .unavailable)
        abandonedSources.insert(scope.source)
        lanes[scope.source]?.pumping = false
        if sealed { lanes[scope.source]?.closed = true; finishAbandonedCaptureIfSettled() }
    }
    func abandonCurrentSource(_ source: LiveSource) {
        guard let lane = lanes[source] else { return }
        abandonSource(scope: .init(identity: input.identity,source: source,epochID: lane.epoch.id))
    }
    nonisolated func belongs(to identity: LiveSessionIdentity, store: LiveTranscriptStore, validity: RecordingDerivativeValidity) -> Bool {
        input.identity == identity && self.store === store && self.validity === validity
    }
    private var isValidOwner: Bool { validity.map { (try? $0.withValidResult { true }) == true } ?? true }

    private var canStart: Bool {
        !started && !terminal && isValidOwner && !invalidIngress && !invalidOwnerBinding && input.isValid && input.epochs.count <= epochHistoryLimit &&
            (input.vad == nil || moduleLedger != nil) && store.identity == input.identity &&
            (input.configuration.identity == nil || preparation != nil) &&
            (lease.map { $0.identity == input.identity && $0.request.chunkMs == input.configuration.chunkMs &&
                $0.request.sourceCount == input.epochs.count && $0.request.vad == input.vad &&
                $0.request.asr == input.configuration.identity &&
                input.epochs.allSatisfy { $0.engineRevision == lease?.request.modelRevision } } ?? true)
    }
    func start() async throws {
        guard canStart else { throw LiveProtocolError.invalidConfiguration }
        if input.vad != nil && preparation == nil {
            guard let resources, let lease, await resources.validateActiveLease(lease), canStart else {
                throw LiveProtocolError.invalidConfiguration
            }
        }
        started = true
        for epoch in input.epochs {
            lanes[epoch.source] = Lane(epoch: epoch); knownEpochs.insert(epoch.id)
            registeredEpochs.append(epoch); capturedByEpoch[epoch.id] = 0; publish(.begin(epoch))
        }
        guard !closing, ingress?.nativeStartAvailable ?? true else { beginClosing(); return }
        armTimer(preparationDeadline, reason: .preparation)
        beginTask = Task { [weak self] in await self?.beginNative() }
    }

    private func beginNative() async {
        guard !terminal, !closing, isValidOwner else { return }
        do {
            if let preparation {
                let prepared = try await preparation.prepare(owner: preparationOwner)
                guard canDispatchNative else { preparation.complete(.cancelled,owner: preparationOwner); beginClosing(); return }
                try await preparation.validatePreparedStart(prepared,owner: preparationOwner)
                guard canDispatchNative, preparation.claimTransfer(prepared,owner: preparationOwner) else {
                    preparation.complete(.cancelled,owner: preparationOwner); beginClosing(); return
                }
                lease = prepared.lease
            } else {
                guard canDispatchNative, ingress?.claimNativeBegin(owner: preparationOwner) ?? true else { beginClosing(); return }
            }
            // No await between the exact ingress claim, receipt adoption and
            // dispatch latch. Subsequent Stop owns actual native shutdown.
            nativeBeginRequested = true
            nativeOwnership = LiveNativeSessionOwnership(owner: preparationOwner,input: input,transport: transport,ingress: ingress,
                resources: resources,lease: lease,preparation: preparation,store: store)
            let stream = try await transport.begin(input)
            nativeOwnership?.beginReturned(); attach(stream)
        } catch {
            nativeOwnership?.beginReturned()
            guard !terminal else { return }
            if !nativeBeginRequested && (closing || !(ingress?.nativeStartAvailable ?? true)) { beginClosing(); return }
            terminate(isValidOwner ? .unavailable : .stopped)
        }
    }

    private var canDispatchNative: Bool { !terminal && !closing && isValidOwner && !Task.isCancelled && (ingress?.nativeStartAvailable ?? true) }

    /// Only the already registered stream may use closingTail, before its EOF.
    /// Unsent frames and frames awaiting a reply stay charged until consumption.
    func offer(scope: LiveLaneScope, samples: [Float], closingTail: Bool = false,
               reservation: LiveCaptureIngress.NormalizedReservation? = nil) -> LiveCaptureAdmission {
        guard started, !terminal, !sealed, isValidOwner, scope.identity == input.identity,
              var lane = lanes[scope.source], lane.epoch.id == scope.epochID, !lane.closed, !abandonedSources.contains(scope.source),
              (!closing || closingTail), (1...3200).contains(samples.count), samples.allSatisfy(\.isFinite),
              samples.count <= (maximumPacketSamples(scope: scope) ?? 0) else { return .rejected }
        if let ingress {
            guard let reservation, reservation.owner === ingress, reservation.scope == scope,
                  reservation.contains(samples.count) else { return .rejected }
        } else if reservation != nil { return .rejected }
        if let reason = ingress?.continuityLoss(scope: scope) {
            reservation?.recordLoss(reason: reason)
            _ = reservation?.discard(samples.count)
            cut(scope.source,reason: reason); return .dropped
        }
        let end = lane.captured.addingReportingOverflow(Int64(samples.count))
        guard !end.overflow, evidence(lane.epoch, lane.captured, end.partialValue) != nil else { terminate(.unknownClock); return .rejected }
        lane.captured = end.partialValue
        if !lane.ready || lane.cutReason != nil {
            guard recordCaptured(scope.source,lane) else { return .dropped }
            _ = reservation?.discard(samples.count)
            cut(scope.source, reason: lane.cutReason ?? .preparation); return .dropped
        }
        guard lane.captured - lane.consumed <= Int64(input.configuration.pendingSampleLimit),
              lane.packets.count < 64, lane.receipts.count < 128, lane.nextPacket < UInt64.max - 1 else {
            guard recordCaptured(scope.source,lane) else { return .dropped }
            _ = reservation?.discard(samples.count)
            cut(scope.source, reason: .overload); return .dropped
        }
        do {
            let packet = try LiveAudioPacket(scope: scope,sequence: lane.nextPacket,startSample: lane.scheduled,samples: samples)
            if let ingress, let reservation, !ingress.schedule(reservation,start: lane.scheduled,count: samples.count) {
                if let reason = ingress.continuityLoss(scope: scope) {
                    // A producer can lose raw audio after conversion but before
                    // this atomic transfer. It cannot extend qualified progress.
                    reservation.recordLoss(reason: reason)
                    _ = reservation.discard(samples.count)
                    cut(scope.source,reason: reason); return .dropped
                }
                guard recordCaptured(scope.source,lane) else { return .dropped }
                _ = reservation.discard(samples.count)
                cut(scope.source,reason: .overload); return .dropped
            }
            lane.nextPacket += 1; lane.scheduled = lane.captured
            lane.packets.append(packet); lane.receipts[packet.sequence] = lane.captured
            guard recordCaptured(scope.source,lane) else { return .dropped }
            if lane.captured - lane.utteranceOrigin == Self.maximumUtteranceSamples {
                _ = enqueueUtteranceBoundary(scope: scope)
            }
            kick(scope.source); return .scheduled
        } catch { _ = recordCaptured(scope.source,lane); _ = reservation?.discard(samples.count); terminate(.unavailable); return .rejected }
    }

    private func recordCaptured(_ source: LiveSource, _ lane: Lane) -> Bool {
        lanes[source] = lane; capturedByEpoch[lane.epoch.id] = lane.captured
        return publishProgress(source)
    }

    func beginClosing() {
        guard !invalidOwnerBinding, !terminal, !closing else { return }
        closing = true; publish(.clearPartials(nil))
        ingress?.closeInput()
        if !nativeBeginRequested {
            preparation?.complete(.cancelled,owner: preparationOwner)
            beginTask?.cancel()
        }
        // A command may accept after cancellation. The old scope cannot then
        // receive a finish barrier; settle only that source without joining it.
        for (source,pending) in replacements {
            abandonSource(scope: .init(identity: input.identity,source: source,epochID: pending.oldEpochID))
        }
    }

    /// Called only after capture streams and converter tails reach EOF. The
    /// independent deadline includes blocked IPC and cancellation-ignoring prep.
    func hardwareDidClose() {
        guard started, !terminal, closing, !sealed else { return }
        for source in lanes.keys { publishIngressLosses(source: source) }
        guard !terminal else { return }
        sealed = true
        guard nativeBeginRequested else { terminate(.stopped); return }
        for source in abandonedSources { lanes[source]?.closed = true }
        finishAbandonedCaptureIfSettled()
        guard !terminal else { return }
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
    func maximumPacketSamples(scope: LiveLaneScope) -> Int? {
        guard started, !sealed, !terminal, isValidOwner, scope.identity == input.identity,
              let lane = lanes[scope.source], lane.epoch.id == scope.epochID, !lane.closed, !lane.paused, lane.pauseBoundary == nil,
              !abandonedSources.contains(scope.source) else { return nil }
        if !lane.ready || lane.cutReason != nil { return 3200 }
        return Int(min(3200,max(0,Self.maximumUtteranceSamples - (lane.captured - lane.utteranceOrigin))))
    }
    /// One exact boundary per source. Later packets retain their finite app
    /// credits until settlement and acknowledgment release this control slot.
    func requestUtteranceBoundary(scope: LiveLaneScope) -> Bool {
        guard !closing else { return false }
        return enqueueUtteranceBoundary(scope: scope)
    }
    private func enqueueUtteranceBoundary(scope: LiveLaneScope) -> Bool {
        guard scope.identity == input.identity, lanes[scope.source]?.epoch.id == scope.epochID else { return false }
        observeIngressLoss(source: scope.source)
        guard started, !sealed, !terminal, isValidOwner, scope.identity == input.identity,
              let lane = lanes[scope.source], lane.epoch.id == scope.epochID, lane.ready,
              lane.cutReason == nil, !lane.closed, !lane.paused, lane.pauseBoundary == nil,
              !abandonedSources.contains(scope.source) else { return false }
        if let pending = lane.utteranceBoundary { return pending.sampleEnd == lane.captured }
        guard lane.captured > lane.settled else { return false }
        lanes[scope.source]?.utteranceBoundary = .init(scope: scope,nextPacketSequence: lane.nextPacket,sampleEnd: lane.captured,kind: .utterance)
        lanes[scope.source]?.utteranceOrigin = lane.captured
        kick(scope.source); return true
    }
    func recordCaptureLoss(owner: LiveSessionIdentity, loss: LiveCaptureRawLoss) -> Bool {
        guard started, !sealed, !terminal, isValidOwner, owner == input.identity,
              lanes[loss.source] != nil, loss.isValid else { return false }
        return publish(.rawLoss(loss))
    }

    /// Drain the finite raw inbox only after reserving enough ordered outbox
    /// space. On overload terminate drains it through the reserved terminal path.
    func publishIngressLosses(source: LiveSource) {
        guard started, !sealed, !terminal, isValidOwner, lanes[source] != nil, let ingress else { return }
        observeIngressLoss(source: source)
        guard publications.count <= 512 - 128 else { terminate(.overload); return }
        let losses = ingress.takeLosses(source)
        // Once taken, every raw fact belongs to this core. Reserve the entire
        // batch before appending, or move all of it into terminal recovery.
        do {
            let batch = try losses.map { PendingPublication(value: .rawLoss($0), bytes: try publicationCharge(.rawLoss($0))) }
            let bytes = batch.reduce(0) { $0 + $1.bytes }
            guard publicationByteLimit.map({ bytes <= $0 - pendingPublicationBytes }) ?? true else {
                for loss in losses { appendTerminal(.rawLoss(loss)) }
                terminate(.overload); return
            }
            pendingPublicationBytes += bytes; publications.append(contentsOf: batch); startPublisher()
        } catch {
            for loss in losses { appendTerminal(.rawLoss(loss)) }
            terminate(.overload)
        }
    }
    func retire() { terminate(.stopped) }
    /// Retry only after the control cut is acknowledged. Native retirement may
    /// still return unavailable; neither the store nor epoch advances on denial.
    func replaceEpoch(scope: LiveLaneScope, epoch: LiveEpoch) async throws -> Bool {
        guard let lane = replacementLane(scope), replacements[scope.source] == nil, replacementCapacity[scope.source] == nil,
              knownEpochs.count + replacementCapacity.count < epochHistoryLimit,
              !knownEpochs.contains(epoch.id), !replacementCapacity.values.contains(where: { $0.proposedID == epoch.id }),
              epoch.source == scope.source, epoch.language == input.configuration.language.rawValue,
              epoch.engineRevision == lane.epoch.engineRevision, epoch.availability == .active,
              epoch.meetingOriginNanoseconds.map({ $0 >= 0 }) ?? true else { return false }
        let pending = Replacement(attemptID: UUID(),oldScope: scope,controlID: lane.controlID,epoch: epoch)
        replacements[scope.source] = pending
        replacementCapacity[scope.source] = .init(attemptID: pending.attemptID,oldScope: scope,proposedID: epoch.id)
        await synchronizeStore()
        guard replacementIsCurrent(pending,beforeDispatch: true), !Task.isCancelled else {
            discardReplacement(pending,releaseCapacity: true); return false
        }
        let preflight: LiveStoreAdmission
        if let check = storeAccess.checkEpoch { preflight = await check(input.identity,epoch) }
        else { preflight = await store.checkEpoch(owner: input.identity,epoch: epoch) }
        guard preflight == .accepted, replacementIsCurrent(pending,beforeDispatch: true), !Task.isCancelled,
              replacementCapacity[scope.source]?.attemptID == pending.attemptID else {
            discardReplacement(pending,releaseCapacity: true); return false
        }
        let reply: LiveSessionReply
        do { reply = try await transport.command(.replaceEpoch(identity: input.identity,oldEpochID: scope.epochID,epoch: epoch)) }
        // The helper may have accepted before transport failed. Retain this
        // exact unresolved capacity/UUID until observed process exit.
        catch { abandonSource(scope: scope); throw error }
        if reply == .accepted {
            guard !helperExited else { return false }
            guard let capacity = replacementCapacity[scope.source], capacity.attemptID == pending.attemptID,
                  capacity.oldScope == scope, capacity.proposedID == epoch.id else { terminate(.unavailable); return false }
            replacementCapacity[scope.source] = nil
            guard knownEpochs.insert(epoch.id).inserted else { terminate(.unavailable); return false }
        } else {
            let emitted = replacements[scope.source]?.attemptID == pending.attemptID && !(replacements[scope.source]?.events.isEmpty ?? true)
            discardReplacement(pending,releaseCapacity: true)
            if emitted { terminate(.unavailable) }
            return false
        }
        guard replacementIsCurrent(pending), !Task.isCancelled else { abandonSource(scope: scope); return false }
        // Pause may freeze already reserved raw input while an earlier native
        // recovery command is in flight. Keep accepted ownership and its small
        // event inbox until the serial consumer disposes that exact old work.
        // Stop/source timeout can abandon this wait without joining native.
        let deadline = ContinuousClock.now.advanced(by: preparationDeadline)
        while true {
            guard replacementIsCurrent(pending), knownEpochs.contains(epoch.id), !Task.isCancelled else {
                abandonSource(scope: scope); return false
            }
            let installation = ingress?.installReplacement(old: scope,new: epoch) ?? .accepted
            if installation == .accepted { break }
            guard installation == .blockedByPause else { abandonSource(scope: scope); return false }
            guard ContinuousClock.now < deadline else { abandonSource(scope: scope); return false }
            do { try await Task.sleep(for: .milliseconds(2)) }
            catch { abandonSource(scope: scope); return false }
        }
        guard replacementIsCurrent(pending), knownEpochs.contains(epoch.id),
              let accepted = replacements.removeValue(forKey: scope.source), accepted.attemptID == pending.attemptID else { return false }
        // The detached inbox remains resident through synchronous replay. New
        // publications acquire their own charge before this one returns.
        defer { pendingPublicationBytes -= accepted.bytes }
        if var ledger = moduleLedger {
            do { try ledger.installAcceptedReplacement(oldScope: scope,newScope: .init(identity: input.identity,source: epoch.source,epochID: epoch.id)) }
            catch { terminate(.unavailable); return false }
            moduleLedger = ledger
        }
        registeredEpochs.append(epoch); capturedByEpoch[epoch.id] = 0
        lanes[scope.source] = Lane(epoch: epoch)
        guard publish(.begin(epoch)) else { return false }
        // The event stream and reply reader are independent. Hold a fixed small
        // inbox until the accepted replacement has installed its outer epoch.
        for event in accepted.events { receive(.lane(event)) }
        return !terminal
    }

    private func replacementLane(_ scope: LiveLaneScope) -> Lane? {
        guard started, !closing, !terminal, isValidOwner, scope.identity == input.identity,
              !abandonedSources.contains(scope.source), let lane = lanes[scope.source], lane.epoch.id == scope.epochID,
              !lane.closed, !lane.pumping, lane.pauseBoundary == nil, moduleRetired(scope.source),
              (lane.paused && lane.settled == lane.captured || lane.cutReason != nil && lane.cutAcknowledgedEnd == lane.captured) else { return nil }
        return lane
    }

    private func replacementIsCurrent(_ pending: Replacement, beforeDispatch: Bool = false) -> Bool {
        let scope = pending.oldScope
        guard !closing, !terminal, isValidOwner, !abandonedSources.contains(scope.source),
              replacements[scope.source]?.attemptID == pending.attemptID,
              scope.identity == input.identity, lanes[scope.source]?.epoch.id == scope.epochID else { return false }
        // Before native dispatch a new cut invalidates preflight. After actual
        // acceptance, dropped old capture may advance its gap/clock frontier;
        // exact operational ownership still permits the established clock-only
        // degradation at publication, without losing the accepted native owner.
        return !beforeDispatch || replacementLane(scope)?.controlID == pending.controlID
    }

    private func discardReplacement(_ pending: Replacement, releaseCapacity: Bool) {
        let source = pending.oldScope.source
        if replacements[source]?.attemptID == pending.attemptID { removeReplacement(source) }
        if releaseCapacity, replacementCapacity[source]?.attemptID == pending.attemptID { replacementCapacity[source] = nil }
        kick(source)
    }

    private func removeReplacement(_ source: LiveSource) {
        if let value = replacements.removeValue(forKey: source) { pendingPublicationBytes -= value.bytes }
    }

    /// Device/stream discontinuity retires only this source's provisional work.
    func recordDiscontinuity(scope: LiveLaneScope, reason: LiveGapReason) {
        guard !closing, !terminal, isValidOwner, scope.identity == input.identity,
              lanes[scope.source]?.epoch.id == scope.epochID else { return }
        cut(scope.source,reason: reason)
    }

    private func attach(_ stream: AsyncThrowingStream<LiveSessionEvent, Error>) {
        guard !terminal else {
            if let nativeOwnership { nativeOwnership.shutdown() }
            else { let transport = self.transport; Task { await transport.shutdown() } }
            return
        }
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
            terminate(nil,privacyOutcome: .succeeded)
        case .lane(let event):
            guard event.scope.identity == input.identity else { return }
            if var pending = replacements[event.scope.source], pending.epoch.id == event.scope.epochID {
                guard pending.events.count < 16, event.sequence == UInt64(pending.events.count) else { terminate(.unavailable); return }
                guard let bytes = try? retainedPublicationCharge(event),
                      publicationByteLimit.map({ bytes <= $0 - pendingPublicationBytes }) ?? true else { terminate(.overload); return }
                pendingPublicationBytes += bytes; pending.bytes += bytes
                pending.events.append(event); replacements[event.scope.source] = pending; return
            }
            guard !abandonedSources.contains(event.scope.source), var lane = lanes[event.scope.source], lane.epoch.id == event.scope.epochID else { return }
            guard event.sequence == lane.nextEvent, event.sequence < .max else { terminate(.unavailable); return }
            lane.nextEvent += 1; lanes[event.scope.source] = lane
            let source = event.scope.source
            observeIngressLoss(source: source)
            guard !terminal, let current = lanes[source] else { return }
            lane = current
            switch event.payload {
            case .vad(let status):
                guard var ledger = moduleLedger else { terminate(.unavailable); return }
                do { try ledger.observe(scope: event.scope,event: status,admittedEnd: lane.moduleAdmittedEnd) }
                catch { terminate(.unavailable); return }
                moduleLedger = ledger
                if ledger.allModelsReady { Task { [weak self] in await self?.confirmVADResidency() } }
            case .ready(_, let origin):
                if let ledger = moduleLedger {
                    guard let module = ledger.status(for: source), module.scope == event.scope,
                          module.phase == .active || module.phase == .degraded else { terminate(.unavailable); return }
                }
                guard origin == lane.settled, !lane.closed, !lane.paused else { cut(source,reason: .engineRestart); return }
                if lane.cutReason == nil {
                    lanes[source]?.ready = true
                    if lane.utteranceBoundary == nil { lanes[source]?.utteranceOrigin = origin }
                }
                if lanes.values.allSatisfy({ $0.ready || $0.paused }) {
                    if !sealed { timer?.cancel(); timerGeneration = nil }
                    if let resources, let lease { Task { await resources.confirmResident(lease) } }
                }
                kick(source)
            case .admitted(let sequence, let end):
                if moduleLedger != nil {
                    guard sequence == lane.nextModuleAcknowledgment, lane.moduleReceipts[sequence] == end,
                          end > lane.moduleAdmittedEnd, end <= lane.dispatched else { terminate(.unavailable); return }
                    lanes[source]?.nextModuleAcknowledgment += 1; lanes[source]?.moduleReceipts[sequence] = nil
                    lanes[source]?.moduleAdmittedEnd = end
                }
                guard lane.cutReason == nil else { return }
                guard sequence == lane.nextAcknowledgedPacket, lane.receipts[sequence] == end, end <= lane.dispatched,
                      end >= lane.admitted else { terminate(.unavailable); return }
                lanes[source]?.nextAcknowledgedPacket += 1; lanes[source]?.receipts[sequence] = nil
                lanes[source]?.admitted = end; publishProgress(source)
            case .progress(let p):
                if let ledger = moduleLedger {
                    guard let module = ledger.status(for: source), module.scope == event.scope,
                          p.asrConsumedSampleEnd != nil, p.admittedSampleEnd == lane.moduleAdmittedEnd,
                          (module.nativeFailureSeen || p.consumedSampleEnd <= module.processedEnd) else { terminate(.unavailable); return }
                }
                guard lane.cutReason == nil else { return }
                let pending = p.queuedSamples.addingReportingOverflow(p.inFlightSamples)
                let total = pending.partialValue.addingReportingOverflow(p.heldSamples)
                guard (input.vad == nil || p.asrConsumedSampleEnd != nil),
                      !pending.overflow, !total.overflow, p.queuedSamples >= 0, p.inFlightSamples >= 0, p.heldSamples >= 0,
                      p.capturedSampleEnd >= p.admittedSampleEnd, p.capturedSampleEnd <= lane.dispatched,
                      p.admittedSampleEnd >= lane.admitted, p.admittedSampleEnd <= lane.dispatched,
                      p.consumedSampleEnd >= lane.consumed, p.consumedSampleEnd <= p.effectiveASRConsumedSampleEnd,
                      p.effectiveASRConsumedSampleEnd >= lane.asrConsumed, p.effectiveASRConsumedSampleEnd <= p.admittedSampleEnd,
                      total.partialValue == p.admittedSampleEnd - p.consumedSampleEnd,
                      total.partialValue <= Int64(input.configuration.pendingSampleLimit),
                      p.creditSamples == (lane.closed || lane.paused ? 0 : Int64(input.configuration.pendingSampleLimit) - total.partialValue) else { terminate(.unavailable); return }
                if let ingress, !ingress.consume(scope: event.scope,end: p.consumedSampleEnd) { terminate(.unavailable); return }
                lanes[source]?.admitted = p.admittedSampleEnd; lanes[source]?.consumed = p.consumedSampleEnd
                lanes[source]?.asrConsumed = p.effectiveASRConsumedSampleEnd
                publishProgress(source)
            case .partial(let partial):
                guard !closing, lane.cutReason == nil, !lane.paused, lane.pauseBoundary == nil else { return }
                guard partial.epochID == lane.epoch.id, partial.source == source, partial.samples.isValid,
                      partial.samples.start >= lane.settled, partial.samples.end <= lane.admitted, partial.text.utf8.count <= 8192 else { terminate(.unavailable); return }
                publish(.event(lane.epoch,.partial(partial)))
            case .committed(let segment):
                guard lane.cutReason == nil else { return }
                guard segment.id.epochID == lane.epoch.id, segment.source == source, segment.isValid,
                      segment.range.meeting == nil, segment.range.savedAudio.isEmpty,
                      let samples = segment.range.samples, samples.start == lane.settled, samples.end <= lane.asrConsumed,
                      let range = evidence(lane.epoch,samples.start,samples.end) else { terminate(.unavailable); return }
                let mapped = CommittedLiveSegment(id: segment.id,source: source,range: range,text: segment.text,
                    words: segment.words,language: segment.language,diarizerContextID: segment.diarizerContextID)
                if publish(.event(lane.epoch,.committed(mapped))) { lanes[source]?.settled = samples.end }
            case .settled(let interval):
                guard lane.cutReason == nil else { return }
                guard interval.epochID == lane.epoch.id, interval.source == source, interval.kind != .committed,
                      interval.committedSegmentID == nil, interval.range.meeting == nil, interval.range.savedAudio.isEmpty,
                      let samples = interval.range.samples, samples.start == lane.settled,
                      samples.end <= (interval.kind == .processedSilence ? lane.asrConsumed : lane.captured),
                      let range = evidence(lane.epoch,samples.start,samples.end) else { terminate(.unavailable); return }
                if publish(.event(lane.epoch,.settled(.init(epochID: lane.epoch.id,source: source,range: range,kind: interval.kind)))) { lanes[source]?.settled = samples.end }
            case .needsEpochReplacement: cut(source,reason: lane.cutReason ?? .engineRestart)
            case .barrierCompleted(_, let kind, let end):
                if kind == .pause || kind == .finish {
                    guard moduleRetired(source) else { terminate(.unavailable); return }
                }
                if kind == .pause {
                    guard lane.cutReason == nil else { return }
                    guard let boundary = lane.pauseBoundary, lane.pauseBoundarySent,
                          end == boundary.sampleEnd, lane.settled == end else { cut(source,reason: .engineRestart); return }
                    lanes[source]?.pauseBoundary = nil; lanes[source]?.pauseBoundarySent = false
                    lanes[source]?.paused = true; lanes[source]?.ready = false
                    publish(.event(lane.epoch,.availability(.paused)))
                    if !sealed, lanes.values.allSatisfy({ $0.ready || $0.paused }) { timer?.cancel(); timerGeneration = nil }
                    kick(source); return
                }
                if kind == .utterance {
                    guard lane.cutReason == nil else { return }
                    guard let boundary = lane.utteranceBoundary, lane.utteranceBoundarySent,
                          end == boundary.sampleEnd, lane.settled == end else { cut(source,reason: .engineRestart); return }
                    lanes[source]?.utteranceBoundary = nil; lanes[source]?.utteranceBoundarySent = false
                    kick(source); return
                }
                guard kind == .finish, sealed, lane.finishSent, end == lane.captured else { terminate(.unavailable); return }
            case .closed(let end):
                guard moduleRetired(source), sealed, lane.finishSent, end == lane.captured, lane.settled == lane.captured else { terminate(.unavailable); return }
                lanes[source]?.closed = true; lanes[source]?.ready = false
                finishAbandonedCaptureIfSettled()
            }
        }
    }

    private func confirmVADResidency() async {
        guard !terminal, isValidOwner, moduleLedger?.allModelsReady == true, let resources, let lease else { return }
        await resources.confirmVADResident(lease)
    }

    private func moduleRetired(_ source: LiveSource) -> Bool {
        guard let ledger = moduleLedger else { return true }
        guard let module = ledger.status(for: source), let lane = lanes[source] else { return false }
        return module.scope == .init(identity: input.identity,source: source,epochID: lane.epoch.id) && module.phase == .retired
    }

    private func finishAbandonedCaptureIfSettled() {
        guard sealed, !abandonedSources.isEmpty,
              lanes.values.allSatisfy({ $0.closed && $0.settled == $0.captured }) else { return }
        // Logical source closure never returns native credit. Termination's
        // dedicated shutdown owner observes process exit before freeing it.
        terminate(nil)
    }

    /// EOF can produce no output, and IPC settlement can race a later producer
    /// loss. Neither path may flush the still provisional prefix across it.
    private func observeIngressLoss(source: LiveSource) {
        guard !terminal, isValidOwner, !abandonedSources.contains(source), let lane = lanes[source], !lane.closed,
              lane.cutReason == nil, (!(sealed || lane.paused) || lane.settled < lane.captured),
              let reason = ingress?.continuityLoss(scope: .init(identity: input.identity,source: source,epochID: lane.epoch.id)) else { return }
        cut(source,reason: reason)
    }
    private func cut(_ source: LiveSource, reason: LiveGapReason) {
        guard !terminal, var lane = lanes[source], !lane.closed else { return }
        lane.controlID = UUID()
        lane.ready = false; lane.cutReason = reason; lane.packets.removeAll(); lane.receipts.removeAll()
        lane.utteranceBoundary = nil; lane.utteranceBoundarySent = false
        lane.pauseBoundary = nil; lane.pauseBoundarySent = false; lane.paused = false
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
        guard !terminal, !abandonedSources.contains(source), eventsTask != nil, replacements[source] == nil, let lane = lanes[source], !lane.pumping, !lane.closed else { return }
        lanes[source]?.pumping = true
        let transport = self.transport
        Task { [weak self] in
            while let request = await self?.nextCommand(source) {
                do { let reply = try await transport.command(request); await self?.commandCompleted(source,request,reply) }
                catch { await self?.commandFailed(source) }
            }
        }
    }

    private func nextCommand(_ source: LiveSource) -> LiveSessionRequest? {
        guard isValidOwner else { terminate(.stopped); return nil }
        observeIngressLoss(source: source)
        guard !terminal, !abandonedSources.contains(source), var lane = lanes[source], !lane.closed else { return nil }
        let scope = LiveLaneScope(identity: input.identity,source: source,epochID: lane.epoch.id)
        if let reason = lane.cutReason, lane.cutAcknowledgedEnd < lane.captured {
            return .cut(scope: scope,nextPacketSequence: lane.nextDispatchedPacket,sampleEnd: lane.captured,reason: reason)
        }
        if let boundary = lane.utteranceBoundary {
            if lane.utteranceBoundarySent { lanes[source]?.pumping = false; return nil }
            guard lane.nextDispatchedPacket <= boundary.nextPacketSequence else { cut(source,reason: .engineRestart); return nil }
            if lane.nextDispatchedPacket == boundary.nextPacketSequence {
                lanes[source]?.utteranceBoundarySent = true; return .barrier(boundary)
            }
        }
        if let boundary = lane.pauseBoundary {
            if lane.pauseBoundarySent { lanes[source]?.pumping = false; return nil }
            guard lane.nextDispatchedPacket <= boundary.nextPacketSequence else { cut(source,reason: .engineRestart); return nil }
            if lane.nextDispatchedPacket == boundary.nextPacketSequence {
                lanes[source]?.pauseBoundarySent = true; return .barrier(boundary)
            }
        }
        if !lane.packets.isEmpty {
            let packet = lane.packets.removeFirst(); lane.dispatched = packet.startSample + Int64(packet.sampleCount)
            if let ingress, !ingress.markDispatched(scope: scope,end: lane.dispatched) { terminate(.unavailable); return nil }
            if moduleLedger != nil { lane.moduleReceipts[packet.sequence] = lane.dispatched }
            lane.nextDispatchedPacket = packet.sequence + 1; lanes[source] = lane; return .packet(packet)
        }
        if sealed && !lane.finishSent {
            lanes[source]?.finishSent = true
            return .barrier(.init(scope: scope,nextPacketSequence: lane.nextDispatchedPacket,sampleEnd: lane.captured,kind: .finish))
        }
        lanes[source]?.pumping = false; return nil
    }

    private func commandCompleted(_ source: LiveSource, _ request: LiveSessionRequest, _ reply: LiveSessionReply) {
        guard !terminal, !abandonedSources.contains(source) else { return }
        if reply != .accepted {
            // A rejected packet has still advanced the helper capture frontier;
            // a control cut is ordered after it and preserves the exact prefix.
            if case .packet = request { cut(source,reason: .unavailable) }
            else if case .barrier(let boundary) = request, boundary.kind == .utterance || boundary.kind == .pause { cut(source,reason: .unavailable) }
            else { terminate(.unavailable) }
            return
        }
        if case .cut(_, _, let end, _) = request { lanes[source]?.cutAcknowledgedEnd = end }
    }

    private func commandFailed(_ source: LiveSource) {
        guard !terminal, !abandonedSources.contains(source) else { return }
        terminate(.unavailable)
    }

    private func armTimer(_ duration: Duration, reason: LiveGapReason) {
        timer?.cancel()
        let generation = UUID(); timerGeneration = generation
        let sleep = deadlineSleep
        timer = Task { [weak self] in
            do { try await sleep(duration) } catch { return }
            await self?.deadlineExpired(generation,reason: reason)
        }
    }

    private func deadlineExpired(_ generation: UUID, reason: LiveGapReason) {
        guard timerGeneration == generation else { return }
        terminate(reason)
    }

    private func terminate(_ reason: LiveGapReason?, privacyOutcome: PrivacyAttempt.Outcome? = nil) {
        guard !terminal else { return }
        if invalidOwnerBinding {
            // Rejected binding grants no authority over a store or ingress
            // already owned by the original coordinator.
            terminal = true; closing = true; sealed = true; closureFailed = true
            let waiters = closureWaiters; closureWaiters.removeAll()
            for waiter in waiters { waiter.resume(throwing: LiveProtocolError.invalidConfiguration) }
            return
        }
        terminal = true; closing = true; sealed = true
        preparation?.complete(privacyOutcome ?? (reason == .stopped ? .cancelled : .failed),owner: preparationOwner)
        ingress?.retireInput()
        pendingPublicationBytes -= replacements.values.reduce(0) { $0 + $1.bytes }
        replacements.removeAll()
        timer?.cancel(); timerGeneration = nil; beginTask?.cancel(); eventsTask?.cancel()
        for source in lanes.keys {
            guard let lane = lanes[source] else { continue }
            lanes[source]?.packets.removeAll(); lanes[source]?.receipts.removeAll(); lanes[source]?.ready = false
            // At most three terminal publications per source beyond the fixed
            // normal inbox. Never discard an already queued evidence commit.
            appendTerminal(.event(lane.epoch,.progress(.init(capturedSampleEnd: lane.captured,admittedSampleEnd: lane.admitted,consumedSampleEnd: lane.consumed,asrConsumedSampleEnd: lane.asrConsumed))))
            if lane.settled < lane.captured, let range = evidence(lane.epoch,lane.settled,lane.captured) {
                appendTerminal(.event(lane.epoch,.settled(.init(epochID: lane.epoch.id,source: source,range: range,kind: .gap(reason ?? .unavailable)))))
                lanes[source]?.settled = lane.captured
            }
            appendTerminal(.event(lane.epoch,.availability(.unavailable)))
        }
        // At most 128 raw facts per registered source, separate from normalized
        // terminal settlement. Keep unknown loss even when the normal inbox fills.
        for source in input.epochs.map(\.source) {
            for loss in ingress?.takeLosses(source) ?? [] { appendTerminal(.rawLoss(loss)) }
        }
        appendTerminal(.close); startPublisher()
        if let nativeOwnership {
            let shutdown = nativeOwnership.shutdown()
            Task { [weak self] in await shutdown.value; await self?.helperDidExit() }
            return
        }
        let transport = self.transport, resources = self.resources, ingress = self.ingress, owner = preparationOwner
        let lease = self.lease.flatMap { $0.identity == input.identity ? $0 : nil }
        Task { [weak self] in
            await transport.shutdown(); ingress?.confirmNativeRetired(owner: owner)
            await self?.helperDidExit()
            if let resources, let lease { await resources.release(lease) }
        }
    }

    private func helperDidExit() {
        helperExited = true
        replacementCapacity.removeAll(); knownEpochs.removeAll()
    }

    @discardableResult private func publishProgress(_ source: LiveSource) -> Bool {
        guard let lane = lanes[source] else { return false }
        return publish(.event(lane.epoch,.progress(.init(capturedSampleEnd: lane.captured,admittedSampleEnd: lane.admitted,consumedSampleEnd: lane.consumed,asrConsumedSampleEnd: lane.asrConsumed))))
    }

    @discardableResult private func publish(_ item: Publication) -> Bool {
        guard !invalidOwnerBinding, !terminal else { return false }
        // Coalesce telemetry/preview only; evidence and boundaries retain order.
        let prior = publications.last
        let replacesProgress: Bool
        if case .event(let epoch, .progress) = item, case .event(let previous, .progress) = prior?.value, epoch == previous {
            replacesProgress = true
        } else { replacesProgress = false }
        guard let bytes = try? publicationCharge(item),
              publicationByteLimit.map({ bytes <= $0 - pendingPublicationBytes + (replacesProgress ? prior?.bytes ?? 0 : 0) }) ?? true,
              replacesProgress || publications.count < 512 else {
            // This fact caused overload before normal enqueue. It still belongs
            // in the bounded terminal inventory, including a removed ingress fact.
            if case .rawLoss = item { appendTerminal(item) }
            terminate(.overload); return false
        }
        let pending = PendingPublication(value: item, bytes: bytes)
        if replacesProgress {
            pendingPublicationBytes += bytes - (prior?.bytes ?? 0)
            publications[publications.count - 1] = pending; return true
        }
        pendingPublicationBytes += bytes
        publications.append(pending); startPublisher(); return true
    }

    private func publicationCharge(_ item: Publication) throws -> Int {
        try retainedPublicationCharge(item)
    }
    private func retainedPublicationCharge(_ value: Any) throws -> Int {
        guard let limit = publicationByteLimit else { return 0 }
        return try LiveArtifactEncoding.estimatedBytes(value, limit: max(1, limit / 4)) * 4
    }
    private func appendTerminal(_ item: Publication) {
        // Terminal controls/raw facts are separately reserved by the recording
        // owner and finite ingress/epoch inventory. They cannot carry new text.
        publications.append(.init(value: item, bytes: 0))
    }

    private func startPublisher() {
        guard publisher == nil else { return }
        publisher = Task { await self.publishStore() }
    }

    private func publishStore() async {
        while !publications.isEmpty {
            let pending = publications.removeFirst(), item = pending.value
            // Removed work is still resident through the actual awaited return.
            defer { pendingPublicationBytes -= pending.bytes }
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
            case .clearPartials(let source): result = await store.clearPartials(owner: input.identity,source: source)
            case .rawLoss(let loss):
                result = terminal ? await store.recordTerminalCaptureLoss(owner: preparationOwner, loss: loss)
                    : await store.recordCaptureLoss(owner: input.identity,loss: loss)
            case .close: result = await store.close(owner: input.identity)
            }
            if case .rejected = result {
                if case .rawLoss = item { publications.insert(.init(value: item, bytes: 0), at: 0) }
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
        let recovery = publications
        let rawLosses = recovery.compactMap { item -> LiveCaptureRawLoss? in
            if case .rawLoss(let loss) = item.value { return loss }; return nil
        }
        publications.removeAll()
        defer { pendingPublicationBytes -= recovery.reduce(0) { $0 + $1.bytes } }
        let projection = await store.projection()
        var recoverySucceeded = true
        for loss in rawLosses {
            let result = await store.recordTerminalCaptureLoss(owner: preparationOwner,loss: loss)
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
                    var result = await store.beginTerminalEpoch(owner: preparationOwner,epoch: epoch)
                    if result == .rejected(.invalidRange) {
                        // An unaccepted clock anchor cannot establish chronology.
                        // Preserve this source's captured samples as unaligned gaps.
                        epoch = .init(id: epoch.id,source: source,engineRevision: epoch.engineRevision,language: epoch.language,
                            meetingOriginNanoseconds: nil,availability: .unavailable)
                        result = await store.beginTerminalEpoch(owner: preparationOwner,epoch: epoch)
                    }
                    guard result == .accepted || result == .duplicate else { recoverySucceeded = false; break }
                    storeSequences[epoch.id] = 0
                }
                let captured = max(existing?.progress.capturedSampleEnd ?? 0,capturedByEpoch[epoch.id] ?? 0)
                var sequence = storeSequences[epoch.id] ?? 0
                let progress = LiveLaneProgress(capturedSampleEnd: captured,
                    admittedSampleEnd: existing?.progress.admittedSampleEnd ?? 0,consumedSampleEnd: existing?.progress.consumedSampleEnd ?? 0,
                    asrConsumedSampleEnd: existing?.progress.effectiveASRConsumedSampleEnd ?? 0)
                let advanced = await store.admitTerminal(owner: preparationOwner, event: .init(identity: input.identity,epochID: epoch.id,source: source,sequence: sequence,payload: .progress(progress)))
                guard advanced == .accepted || advanced == .duplicate else { recoverySucceeded = false; break }
                sequence += 1
                if let range = evidence(epoch,existing?.settledSampleEnd ?? 0,captured) {
                    let settled = await store.admitTerminal(owner: preparationOwner, event: .init(identity: input.identity,epochID: epoch.id,source: source,sequence: sequence,
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
