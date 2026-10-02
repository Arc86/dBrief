import Foundation
import dBriefWire

/// Owns registered source tasks, separately from native preparation/control.
final class LiveCaptureStreamSession: @unchecked Sendable {
    private struct State {
        var registered = false
        var closing = false
        var expired = false
        var start: Task<Void, Never>?
        var consumers: [Task<Void, Never>] = []
        var finalizer: Task<Void, Error>?
    }
    let input: LiveSessionBegin
    let ingress: LiveCaptureIngress
    let coordinator: LiveCaptureSessionCoordinator
    private let lock = NSLock()
    private var state = State()
    private let controls: [LiveSource: LiveCaptureSourceControl]

    init(input: LiveSessionBegin, ingress: LiveCaptureIngress, coordinator: LiveCaptureSessionCoordinator,
         replacementDeadline: Duration = .seconds(30), retryInterval: Duration = .milliseconds(50)) throws {
        guard input.isValid, ingress.matches(input), coordinator.matches(input: input,ingress: ingress),
              replacementDeadline > .zero, replacementDeadline <= .seconds(60),
              retryInterval > .zero, retryInterval <= .seconds(1) else { throw LiveProtocolError.invalidConfiguration }
        self.input = input; self.ingress = ingress; self.coordinator = coordinator
        controls = Dictionary(uniqueKeysWithValues: input.epochs.map {
            ($0.source,LiveCaptureSourceControl(coordinator: coordinator,deadline: replacementDeadline,retryInterval: retryInterval))
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
            state.consumers = streams.map { source, stream in
                Task.detached(priority: .userInitiated) { [self] in
                    await start.value
                    await consume(source: source,stream: stream)
                }
            }
            return true
        }
    }

    private var flags: (closing: Bool,expired: Bool) { lock.withLock { (state.closing,state.expired) } }

    func beginClosing() {
        let changed = lock.withLock {
            guard !state.closing, !state.expired else { return false }
            state.closing = true; ingress.closeInput(); return true
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
            let start = state.start, consumers = state.consumers
            let finalizer = Task { [self] in
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
            state.expired = true; state.closing = true; ingress.retireInput()
            return state.consumers
        }
        guard let tasks else { return }
        for task in tasks { task.cancel() }
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
        },expire: { [self] in expire() })
    }

    private func consume(source: LiveSource, stream: AsyncStream<LiveAudioBuffer>) async {
        guard let control = controls[source] else { return }
        var normalizer: LiveASRNormalizer?
        var skippedEpoch: UUID?
        for await item in stream {
            guard !flags.expired, !Task.isCancelled else { break }
            guard let ticket = item.ingress, ticket.owner === ingress, ticket.source == source else { continue }
            guard let lane = await coordinator.streamState(source: source) else {
                ticket.discard(reason: .stopped); continue
            }
            if !lane.ready {
                normalizer?.cancel(reason: lane.gapReason ?? .unavailable); normalizer = nil
                ticket.discard(reason: lane.gapReason ?? .preparation); skippedEpoch = lane.scope.epochID
                await coordinator.publishIngressLosses(source: source)
                if lane.gapReason != .preparation && !flags.closing { await control.ensure(lane) }
                continue
            }
            if skippedEpoch == lane.scope.epochID {
                // Missing raw input invalidates a prior clock origin. A fresh
                // source-local epoch is required even after initial preparation.
                await coordinator.recordDiscontinuity(scope: lane.scope,reason: .preparation)
                ticket.discard(reason: .preparation)
                await coordinator.publishIngressLosses(source: source)
                if !flags.closing { await control.ensure(lane) }
                continue
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
                        if !flags.closing { await control.ensure(lane) }
                    }
                }
            } catch {
                normalizer?.cancel(reason: .deviceInterruption); normalizer = nil
                ticket.discard(reason: .deviceInterruption)
                await coordinator.recordDiscontinuity(scope: lane.scope,reason: .deviceInterruption)
                if !flags.closing { await control.ensure(lane) }
            }
            await coordinator.publishIngressLosses(source: source)
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

    private func send(_ batch: LiveASRNormalizer.Batch) async -> Bool {
        var scheduled = true
        for start in stride(from: 0,to: batch.samples.count,by: 3200) {
            let end = min(batch.samples.count,start + 3200)
            guard !flags.expired, !Task.isCancelled else { batch.reservation.recordLoss(reason: .stopped); return false }
            let admission = await coordinator.offer(scope: batch.reservation.scope,samples: Array(batch.samples[start..<end]),
                closingTail: flags.closing,reservation: batch.reservation)
            if admission == .rejected { batch.reservation.recordLoss(reason: .unavailable); return false }
            if admission == .dropped { scheduled = false }
        }
        return scheduled
    }
}

/// One source owns at most one candidate, retry task and independent timer.
/// Its command may ignore cancellation; neither PCM consumption nor Stop joins it.
private actor LiveCaptureSourceControl {
    let coordinator: LiveCaptureSessionCoordinator
    let deadline: Duration
    let retryInterval: Duration
    private var stopped = false
    private var generation: UUID?
    private var pendingScope: LiveLaneScope?
    private var failedEpoch: UUID?
    private var retry: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    init(coordinator: LiveCaptureSessionCoordinator, deadline: Duration, retryInterval: Duration) {
        self.coordinator = coordinator; self.deadline = deadline; self.retryInterval = retryInterval
    }
    func ensure(_ lane: LiveCaptureSessionCoordinator.StreamState) {
        guard !stopped, generation == nil, failedEpoch != lane.epoch.id else { return }
        let id = UUID(); generation = id; pendingScope = lane.scope
        let next = LiveEpoch(id: UUID(),source: lane.scope.source,engineRevision: lane.epoch.engineRevision,
            language: lane.epoch.language,meetingOriginNanoseconds: nil)
        timer = Task {
            do { try await Task.sleep(for: deadline) } catch { return }
            await fail(id,scope: lane.scope)
        }
        retry = Task {
            for _ in 0..<256 {
                guard !Task.isCancelled else { return }
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
