import Foundation
import dBriefWire

/// Owns registered source tasks, separately from native preparation/control.
final class LiveCaptureStreamSession: @unchecked Sendable {
    private struct Pause {
        var boundary: LiveCaptureIngress.PauseBoundary
        var drained = false
        var failed = false
        var observer: Task<Void, Never>?
        var generation: UUID?
        var driver: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }
    private struct State {
        var registered = false
        var closing = false
        var expired = false
        var start: Task<Void, Never>?
        var consumers: [Task<Void, Never>] = []
        var finalizer: Task<Void, Error>?
        var wantsPause = false
        var pauses: [LiveSource: Pause] = [:]
        var interruptions: Set<LiveSource> = []
    }
    let input: LiveSessionBegin
    let ingress: LiveCaptureIngress
    let coordinator: LiveCaptureSessionCoordinator
    private let lock = NSLock()
    private var state = State()
    private let controls: [LiveSource: LiveCaptureSourceControl]
    private let mailboxes: [LiveSource: LiveCaptureSourceMailbox]
    private let replacementDeadline: Duration
    private let retryInterval: Duration
    private let deadlineSleep: @Sendable (Duration) async throws -> Void
    private let deadlineHandled: @Sendable () async -> Void

    init(input: LiveSessionBegin, ingress: LiveCaptureIngress, coordinator: LiveCaptureSessionCoordinator,
         replacementDeadline: Duration = .seconds(30), retryInterval: Duration = .milliseconds(50),
         deadlineSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         deadlineHandled: @escaping @Sendable () async -> Void = {}) throws {
        guard input.isValid, ingress.matches(input), coordinator.matches(input: input,ingress: ingress),
              replacementDeadline > .zero, replacementDeadline <= .seconds(60),
              retryInterval > .zero, retryInterval <= .seconds(1) else { throw LiveProtocolError.invalidConfiguration }
        self.input = input; self.ingress = ingress; self.coordinator = coordinator
        self.replacementDeadline = replacementDeadline; self.retryInterval = retryInterval
        self.deadlineSleep = deadlineSleep
        self.deadlineHandled = deadlineHandled
        controls = Dictionary(uniqueKeysWithValues: input.epochs.map {
            ($0.source,LiveCaptureSourceControl(coordinator: coordinator,ingress: ingress,deadline: replacementDeadline,retryInterval: retryInterval))
        })
        mailboxes = Dictionary(uniqueKeysWithValues: try input.epochs.map {
            ($0.source,try LiveCaptureSourceMailbox(ingress: ingress,source: $0.source))
        })
    }

    func register(_ inputs: CaptureLivePreview.Inputs) -> Bool {
        lock.withLock {
            guard !state.registered, !state.closing, !state.expired, inputs.language == input.configuration.language.rawValue else { return false }
            let streams: [(LiveSource,AsyncStream<LiveAudioBuffer>)] = [
                inputs.mic.map { (.microphone,$0) },inputs.system.map { (.system,$0) }
            ].compactMap { $0 }
            guard Set(streams.map(\.0)) == Set(input.epochs.map(\.source)) else { return false }
            state.registered = true
            let start = Task.detached { [self] in
                guard !flags.expired else { return }
                do { try await coordinator.start() } catch { await coordinator.retire() }
            }
            state.start = start
            state.consumers = streams.flatMap { source, stream in
                let mailbox = mailboxes[source]!
                let relay = Task.detached(priority: .userInitiated) { [self] in
                    for await item in stream {
                        guard !flags.expired, !Task.isCancelled else { break }
                        _ = mailbox.offer(item)
                    }
                    mailbox.finish()
                }
                let consumer = Task.detached(priority: .userInitiated) { [self] in
                    await start.value
                    await consume(source: source,mailbox: mailbox)
                }
                return [relay,consumer]
            }
            return true
        }
    }

    private var flags: (closing: Bool,expired: Bool) { lock.withLock { (state.closing,state.expired) } }

    /// This hook runs before hardware Pause. Its lock orders user control with
    /// fresh-epoch admission, while the ingress lock orders raw reservations.
    func pause() {
        lock.withLock {
            guard state.registered, !state.closing, !state.expired else { return }
            state.wantsPause = true
            for source in controls.keys {
                if state.pauses[source] == nil, let boundary = ingress.pauseAdmission(source: source) {
                    state.pauses[source] = Pause(boundary: boundary)
                    observePauseWhileLocked(source)
                }
                if let boundary = state.pauses[source]?.boundary { ingress.setResuming(false,boundary: boundary) }
                drivePauseWhileLocked(source)
                mailboxes[source]?.wake()
            }
        }
    }

    func resume() {
        lock.withLock {
            guard state.registered, !state.closing, !state.expired else { return }
            state.wantsPause = false
            for source in state.pauses.keys {
                if let boundary = state.pauses[source]?.boundary { ingress.setResuming(true,boundary: boundary) }
                drivePauseWhileLocked(source)
                mailboxes[source]?.wake()
            }
        }
    }

    func inputDeviceChanged() {
        lock.withLock {
            guard state.registered, !state.closing, !state.expired, controls[.microphone] != nil else { return }
            // Ordered native settlement can race the serial worker's wake.
            // Retire this source's provisional eligibility synchronously.
            ingress.latchDiscontinuity(.microphone,reason: .deviceInterruption)
            state.interruptions.insert(.microphone); mailboxes[.microphone]?.wake()
        }
    }

    private func sourceIsFrozen(_ source: LiveSource) -> Bool { lock.withLock { state.pauses[source] != nil } }
    private func observePauseWhileLocked(_ source: LiveSource) {
        guard let boundary = state.pauses[source]?.boundary, let updates = ingress.pauseUpdates(boundary),
              let mailbox = mailboxes[source] else { return }
        state.pauses[source]?.observer = Task.detached {
            for await _ in updates {
                guard !Task.isCancelled else { return }
                mailbox.wake()
            }
        }
    }
    private func drivePauseWhileLocked(_ source: LiveSource) {
        guard let pause = state.pauses[source], !pause.failed, pause.generation == nil else { return }
        let id = UUID(); state.pauses[source]?.generation = id
        state.pauses[source]?.timer = Task.detached { [self] in
            do { try await deadlineSleep(replacementDeadline) } catch { return }
            await pauseDeadlineExpired(source,id: id)
            // Injected clocks can acknowledge completed deadline handling,
            // rather than merely returning from their sleep operation.
            await deadlineHandled()
        }
        state.pauses[source]?.driver = Task.detached { [self] in await drivePause(source,id: id) }
    }
    private func drivePause(_ source: LiveSource, id: UUID) async {
        await controls[source]?.suspendRecovery()
        var candidate: LiveEpoch?
        for _ in 0..<512 {
            guard !Task.isCancelled, let snapshot = pauseSnapshot(source,id: id) else { return }
            mailboxes[source]?.wake()
            if snapshot.drained, let lane = await coordinator.streamState(source: source) {
                if lane.scope != snapshot.boundary.scope {
                    if lane.ready {
                        let finished = lock.withLock { () -> Bool in
                            guard !state.closing, !state.expired, state.pauses[source]?.generation == id,
                                  state.pauses[source]?.boundary == snapshot.boundary else { return true }
                            if state.wantsPause {
                                guard let boundary = ingress.rebasePause(snapshot.boundary,scope: lane.scope) else { return false }
                                state.pauses[source]?.observer?.cancel()
                                state.pauses[source]?.boundary = boundary
                                state.pauses[source]?.drained = true
                                observePauseWhileLocked(source)
                                candidate = nil
                                return false
                            }
                            guard ingress.resumeAdmission(snapshot.boundary,scope: lane.scope) else { return false }
                            state.pauses[source]?.observer?.cancel(); state.pauses[source]?.timer?.cancel()
                            state.pauses[source] = nil; return true
                        }
                        if finished { return }
                    }
                } else if lane.ready {
                    // Even an immediate Resume must first retire the frozen
                    // old prefix; desired state cannot bypass its pause seal.
                    _ = await coordinator.requestPauseBoundary(scope: lane.scope,boundary: snapshot.boundary)
                } else if snapshot.wantsPause {
                    let paused = await coordinator.pausedSources.contains(source)
                    if paused || lane.replacementReady {
                        let stillPaused = lock.withLock { () -> Bool in
                            guard state.pauses[source]?.generation == id, state.wantsPause else { return false }
                            state.pauses[source]?.generation = nil; state.pauses[source]?.driver = nil
                            state.pauses[source]?.timer?.cancel(); state.pauses[source]?.timer = nil; return true
                        }
                        if stillPaused { return }
                    }
                } else if lane.replacementReady {
                    if candidate == nil {
                        candidate = .init(id: UUID(),source: source,engineRevision: lane.epoch.engineRevision,
                            language: lane.epoch.language,meetingOriginNanoseconds: nil)
                    }
                    do { _ = try await coordinator.replaceEpoch(scope: lane.scope,epoch: candidate!) }
                    catch { await pauseDeadlineExpired(source,id: id); return }
                }
            }
            do { try await Task.sleep(for: retryInterval) } catch { return }
        }
        await pauseDeadlineExpired(source,id: id)
    }
    private func pauseSnapshot(_ source: LiveSource, id: UUID) -> (boundary: LiveCaptureIngress.PauseBoundary,drained: Bool,wantsPause: Bool)? {
        lock.withLock {
            guard !state.closing, !state.expired, let pause = state.pauses[source], pause.generation == id, !pause.failed else { return nil }
            return (pause.boundary,pause.drained,state.wantsPause)
        }
    }
    private func pauseDeadlineExpired(_ source: LiveSource, id: UUID) async {
        guard pauseSnapshot(source,id: id) != nil else { return }
        let failed = lock.withLock { () -> Bool in
            guard !state.closing, !state.expired, state.pauses[source]?.generation == id else { return false }
            state.pauses[source]?.failed = true; state.pauses[source]?.generation = nil
            state.pauses[source]?.driver?.cancel(); state.pauses[source]?.driver = nil
            state.pauses[source]?.timer?.cancel(); state.pauses[source]?.timer = nil; return true
        }
        if failed { await coordinator.abandonCurrentSource(source) }
    }
    private func cancelPauseTasksWhileLocked() {
        for source in state.pauses.keys {
            state.pauses[source]?.generation = nil
            state.pauses[source]?.observer?.cancel(); state.pauses[source]?.observer = nil
            state.pauses[source]?.driver?.cancel(); state.pauses[source]?.driver = nil
            state.pauses[source]?.timer?.cancel(); state.pauses[source]?.timer = nil
        }
    }

    func beginClosing() {
        let changed = lock.withLock {
            guard !state.closing, !state.expired else { return false }
            state.closing = true; coordinator.sealAttribution(); ingress.closeInput(); cancelPauseTasksWhileLocked(); return true
        }
        guard changed else { return }
        Task {
            await coordinator.beginClosing()
            for control in controls.values { await control.stop() }
        }
    }

    /// The capture owner's independent deadline may cancel this wait; expiry
    /// cancels source tasks without joining their native control operations.
    func hardwareDidClose() async throws {
        beginClosing()
        let finalizer = lock.withLock { () -> Task<Void, Error> in
            if let finalizer = state.finalizer { return finalizer }
            let start = state.start, consumers = state.consumers, registered = state.registered
            let finalizer = Task { [self] in
                if !registered {
                    ingress.retireInput()
                    await coordinator.retire()
                    try await coordinator.waitUntilClosed()
                    return
                }
                await start?.value
                await coordinator.beginClosing()
                for consumer in consumers { await consumer.value }
                guard !flags.expired else { throw LiveProtocolError.closed }
                for source in controls.keys { await coordinator.publishIngressLosses(source: source) }
                await coordinator.hardwareDidClose()
                try await coordinator.waitUntilClosed()
            }
            state.finalizer = finalizer; return finalizer
        }
        try await withTaskCancellationHandler { try await finalizer.value } onCancel: { self.expire() }
    }

    func expire() {
        let tasks = lock.withLock { () -> [Task<Void, Never>]? in
            guard !state.expired else { return nil }
            state.expired = true; state.closing = true; coordinator.sealAttribution(); ingress.retireInput(); cancelPauseTasksWhileLocked()
            return state.consumers
        }
        guard let tasks else { return }
        for task in tasks { task.cancel() }
        for mailbox in mailboxes.values { mailbox.finish() }
        Task {
            await coordinator.retire()
            for control in controls.values { await control.stop() }
        }
    }

    @MainActor func derivativeSession() -> CaptureLiveDerivative.Session {
        .init(identity: input.identity,register: { [self] inputs in
            if !register(inputs) { expire() }
        },beginClosing: { [self] in beginClosing() },hardwareDidClose: { [self] in
            try? await hardwareDidClose()
        },expire: { [self] in expire() },pause: { [self] in pause() },resume: { [self] in resume() },
          inputDeviceChanged: { [self] in inputDeviceChanged() },ingress: ingress,
          registerPrepared: { [self] in register($0) })
    }

    private func consume(source: LiveSource, mailbox: LiveCaptureSourceMailbox) async {
        guard let control = controls[source] else { return }
        var normalizer: LiveASRNormalizer?
        var skippedEpoch: UUID?
        for await event in mailbox.events {
            guard !flags.expired, !Task.isCancelled else { break }
            await handleInterruption(source,normalizer: &normalizer,skippedEpoch: &skippedEpoch)
            if case .audio(let item) = event {
                await consume(item,source: source,control: control,normalizer: &normalizer,skippedEpoch: &skippedEpoch)
            } else { mailbox.consumedWake() }
            await drainPause(source,normalizer: &normalizer)
        }
        if !flags.expired, !Task.isCancelled {
            do {
                if let batch = try normalizer?.finish() { _ = await send(batch) }
            } catch { normalizer?.cancel(reason: .unavailable) }
        } else { normalizer?.cancel(reason: .stopped) }
        await coordinator.publishIngressLosses(source: source)
        await control.stop()
        if !flags.closing, let lane = await coordinator.streamState(source: source) {
            await coordinator.recordDiscontinuity(scope: lane.scope,reason: .deviceInterruption)
        }
    }

    private func handleInterruption(_ source: LiveSource, normalizer: inout LiveASRNormalizer?, skippedEpoch: inout UUID?) async {
        let interrupted = lock.withLock { () -> Bool in
            guard !state.closing, !state.expired else { return false }
            return state.interruptions.remove(source) != nil
        }
        guard interrupted else { return }
        // Only the serial consumer can destroy its real converter. Native
        // replacement must never carry the old device's held tail forward.
        normalizer?.cancel(reason: .deviceInterruption); normalizer = nil; skippedEpoch = nil
        guard let lane = await coordinator.streamState(source: source) else { return }
        await coordinator.recordDiscontinuity(scope: lane.scope,reason: .deviceInterruption)
        await coordinator.publishIngressLosses(source: source)
        if !flags.closing, !sourceIsFrozen(source) { await controls[source]?.ensure(lane) }
    }

    private func consume(_ item: LiveAudioBuffer, source: LiveSource, control: LiveCaptureSourceControl,
                         normalizer: inout LiveASRNormalizer?, skippedEpoch: inout UUID?) async {
        defer { if let ticket = item.ingress { mailboxes[source]?.completedAudio(ticket.id) } }
        guard let ticket = item.ingress, ticket.owner === ingress, ticket.source == source else { return }
        guard let lane = await coordinator.streamState(source: source) else {
            ticket.discard(reason: .stopped); return
        }
        if !lane.ready {
            normalizer?.cancel(reason: lane.gapReason ?? .unavailable); normalizer = nil
            ticket.discard(reason: lane.gapReason ?? .preparation); skippedEpoch = lane.scope.epochID
            await coordinator.publishIngressLosses(source: source)
            if lane.gapReason != .preparation && !flags.closing && !sourceIsFrozen(source) { await control.ensure(lane) }
            return
        }
        if skippedEpoch == lane.scope.epochID {
            // Missing raw input invalidates a prior clock origin. A fresh
            // source-local epoch is required even after initial preparation.
            await coordinator.recordDiscontinuity(scope: lane.scope,reason: .preparation)
            ticket.discard(reason: .preparation)
            await coordinator.publishIngressLosses(source: source)
            if !flags.closing && !sourceIsFrozen(source) { await control.ensure(lane) }
            return
        }
        skippedEpoch = nil
        do {
            if let existing = normalizer, existing.scope != lane.scope, !existing.rebind(to: lane.scope) {
                existing.cancel(reason: .engineRestart); normalizer = nil
            }
            if normalizer == nil { normalizer = try LiveASRNormalizer(scope: lane.scope,ingress: ingress) }
            if let batch = try normalizer?.convert(item) {
                if !(await send(batch)) {
                    normalizer?.cancel(reason: .unavailable); normalizer = nil
                    if !flags.closing && !sourceIsFrozen(source) { await control.ensure(lane) }
                }
            }
        } catch {
            normalizer?.cancel(reason: .deviceInterruption); normalizer = nil
            ticket.discard(reason: .deviceInterruption)
            await coordinator.recordDiscontinuity(scope: lane.scope,reason: .deviceInterruption)
            if !flags.closing && !sourceIsFrozen(source) { await control.ensure(lane) }
        }
        await coordinator.publishIngressLosses(source: source)
    }

    private func drainPause(_ source: LiveSource, normalizer: inout LiveASRNormalizer?) async {
        let boundary = lock.withLock { () -> LiveCaptureIngress.PauseBoundary? in
            guard !state.closing, !state.expired, let pause = state.pauses[source], !pause.drained else { return nil }
            return pause.boundary
        }
        guard let boundary, ingress.pauseReadiness(boundary) == .drained else { return }
        do { if let batch = try normalizer?.finish() { _ = await send(batch) } }
        catch { normalizer?.cancel(reason: .unavailable) }
        normalizer = nil
        await coordinator.publishIngressLosses(source: source)
        lock.withLock {
            guard !state.closing, !state.expired, state.pauses[source]?.boundary == boundary else { return }
            state.pauses[source]?.drained = true
        }
    }

    private func send(_ batch: LiveASRNormalizer.Batch) async -> Bool {
        var scheduled = true
        var start = 0
        while start < batch.samples.count {
            guard !flags.expired, !Task.isCancelled else { batch.reservation.recordLoss(reason: .stopped); return false }
            guard let maximum = await coordinator.maximumPacketSamples(scope: batch.reservation.scope), maximum > 0 else {
                batch.reservation.recordLoss(reason: .unavailable); return false
            }
            let end = min(batch.samples.count,start + maximum)
            let admission = await coordinator.offer(scope: batch.reservation.scope,samples: Array(batch.samples[start..<end]),
                closingTail: flags.closing,reservation: batch.reservation)
            if admission == .rejected { batch.reservation.recordLoss(reason: .unavailable); return false }
            if admission == .dropped { scheduled = false }
            start = end
        }
        return scheduled
    }
}

/// One source owns at most one candidate, retry task and independent timer.
/// Its command may ignore cancellation; neither PCM consumption nor Stop joins it.
private actor LiveCaptureSourceControl {
    let coordinator: LiveCaptureSessionCoordinator
    let ingress: LiveCaptureIngress
    let deadline: Duration
    let retryInterval: Duration
    private var stopped = false
    private var generation: UUID?
    private var pendingScope: LiveLaneScope?
    private var failedEpoch: UUID?
    private var retry: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    init(coordinator: LiveCaptureSessionCoordinator, ingress: LiveCaptureIngress, deadline: Duration, retryInterval: Duration) {
        self.coordinator = coordinator; self.ingress = ingress; self.deadline = deadline; self.retryInterval = retryInterval
    }
    func ensure(_ lane: LiveCaptureSessionCoordinator.StreamState) {
        guard !stopped, !lane.paused, !ingress.isAdmissionPaused(lane.scope.source), generation == nil, failedEpoch != lane.epoch.id else { return }
        let id = UUID(); generation = id; pendingScope = lane.scope
        let next = LiveEpoch(id: UUID(),source: lane.scope.source,engineRevision: lane.epoch.engineRevision,
            language: lane.epoch.language,meetingOriginNanoseconds: nil)
        timer = Task {
            do { try await Task.sleep(for: deadline) } catch { return }
            await fail(id,scope: lane.scope)
        }
        retry = Task {
            for _ in 0..<256 {
                guard !Task.isCancelled, generation == id else { return }
                do {
                    if try await coordinator.replaceEpoch(scope: lane.scope,epoch: next) { complete(id); return }
                    try await Task.sleep(for: retryInterval)
                } catch { break }
            }
            await fail(id,scope: lane.scope)
        }
    }
    private func complete(_ id: UUID) {
        guard generation == id else { return }
        generation = nil; pendingScope = nil; retry = nil; timer?.cancel(); timer = nil
    }
    func suspendRecovery() {
        // An already dispatched command keeps its coordinator ownership and
        // native credits. Pause's independent driver observes its eventual
        // accepted scope; cancellation never claims it has unwound.
        generation = nil; pendingScope = nil
        // The accepted command may need to drain raw input frozen after it was
        // dispatched. Leave that one owner running; the generation check stops
        // further attempts. Stop/the pause deadline still abandon its scope.
        retry = nil; timer?.cancel(); timer = nil
    }
    private func fail(_ id: UUID, scope: LiveLaneScope) async {
        guard generation == id else { return }
        failedEpoch = scope.epochID; generation = nil; pendingScope = nil
        retry?.cancel(); retry = nil; timer?.cancel(); timer = nil
        await coordinator.abandonSource(scope: scope)
    }
    func stop() async {
        stopped = true; generation = nil
        let scope = pendingScope; pendingScope = nil
        retry?.cancel(); retry = nil; timer?.cancel(); timer = nil
        if let scope { await coordinator.abandonSource(scope: scope) }
    }
}
