import Foundation
import dBriefWire

/// The sealed native adapter creates a private driver, including its mutable
/// model buffers. This port cannot reset state or process an entire utterance.
protocol LiveDiarizationDriving: AnyObject, Sendable {
    func append(_ samples: [Float]) async throws -> [LiveDiarizationChunk]
    func finish() async throws -> [LiveDiarizationChunk]
    func shutdown() async
}
protocol LiveDiarizationResourceWitness: AnyObject, Sendable {}

struct LiveDiarizationWorkToken: Sendable, Equatable {
    let contextID: UUID
    let scope: LiveLaneScope
    let id: UUID
}
struct LiveDiarizationBatch: Sendable {
    let token: LiveDiarizationWorkToken
    let frames: [LiveDiarizationFrame]
    let streamSampleEnd: Int64
    let nativeFrameEnd: Int64
    let replay: Bool
}

/// Serial native lifecycle. The producer owns bounded wire admission/publication;
/// acoustic qualification and app pressure admission remain separate.
actor LiveDiarizationSession {
    enum Failure: Error, Equatable { case invalidConfiguration, invalidInput, staleScope, busy, inactive, capacity, failed }
    enum Phase: Sendable { case unprepared, preparing, active, paused, finished, retired }
    struct Snapshot: Sendable {
        let phase: Phase
        let contextID: UUID
        let scope: LiveLaneScope
        let streamSampleEnd: Int64
        let nativeFrameEnd: Int64
        let pendingSamples: Int64
        let epochCount: Int
        let pieceCount: Int
        let hasWork: Bool
        let resourcesHeld: Bool
    }
    typealias Factory = @Sendable () async throws -> any LiveDiarizationDriving
    private final class Resources: Sendable {
        let driver: any LiveDiarizationDriving
        let witness: any LiveDiarizationResourceWitness
        init(driver: any LiveDiarizationDriving, witness: any LiveDiarizationResourceWitness) {
            self.driver = driver; self.witness = witness
        }
    }
    private enum Kind: Sendable { case preparation, append, finish }
    private enum Outcome: Sendable { case prepared(Resources), produced([LiveDiarizationChunk]), failed }
    private struct Work: Sendable {
        let token: LiveDiarizationWorkToken
        let kind: Kind
        let task: Task<Outcome, Never>
        let witness: any LiveDiarizationResourceWitness
        let resources: Resources?
        var claimed = false
    }
    nonisolated let contextID: UUID
    private var timeline: LiveDiarizationTimeline
    private var phase = Phase.unprepared
    private var factory: Factory?
    private var witness: (any LiveDiarizationResourceWitness)?
    private var resources: Resources?
    private var work: Work?
    private var retirement: (UUID, Task<Void, Never>)?
    private var joined = false
    private var terminal: LiveDiarizationBatch?

    init(scope: LiveLaneScope, preset: LiveDiarizationPreset, witness: any LiveDiarizationResourceWitness, sourceOrigin: Int64 = 0, factory: @escaping Factory) throws {
        let context = UUID(); contextID = context
        timeline = try .init(scope: scope, contextID: context, preset: preset, sourceOrigin: sourceOrigin)
        self.witness = witness; self.factory = factory
    }
    func snapshot() -> Snapshot {
        .init(phase: phase, contextID: contextID, scope: timeline.scope, streamSampleEnd: timeline.streamEnd,
            nativeFrameEnd: timeline.frameEnd, pendingSamples: timeline.pendingSamples, epochCount: timeline.epochCount,
            pieceCount: timeline.pieceCount, hasWork: work != nil, resourcesHeld: witness != nil)
    }
    private func token() -> LiveDiarizationWorkToken { .init(contextID: contextID, scope: timeline.scope, id: UUID()) }

    func prepare() async throws -> UUID {
        try Task.checkCancellation()
        guard phase == .unprepared, let factory, let witness else { throw Failure.inactive }
        self.factory = nil; phase = .preparing
        let token = token()
        let task = Task {
            defer { withExtendedLifetime(witness) {} }
            do {
                try Task.checkCancellation()
                return Outcome.prepared(Resources(driver: try await factory(), witness: witness))
            } catch { return Outcome.failed } // Never retain an arbitrary native Error.
        }
        work = .init(token: token, kind: .preparation, task: task, witness: witness, resources: nil)
        _ = try await complete(token)
        return contextID
    }

    func admit(scope: LiveLaneScope, samples: [Float], startSample: Int64, meeting: LiveMeetingRange?) throws -> LiveDiarizationWorkToken {
        try Task.checkCancellation()
        guard scope == timeline.scope else { throw Failure.staleScope }
        guard phase == .active, let resources else { throw Failure.inactive }
        guard work == nil else { throw Failure.busy }
        do { try timeline.admit(scope: scope, samples: samples, start: startSample, meeting: meeting) }
        catch Failure.capacity { retire(); throw Failure.capacity }
        let token = token()
        let task = Task {
            defer { withExtendedLifetime(resources) {}; withExtendedLifetime(samples) {} }
            do { try Task.checkCancellation(); return Outcome.produced(try await resources.driver.append(samples)) }
            catch { return Outcome.failed }
        }
        work = .init(token: token, kind: .append, task: task, witness: resources.witness, resources: resources)
        return token
    }

    func complete(_ token: LiveDiarizationWorkToken) async throws -> LiveDiarizationBatch {
        guard var reservation = work, reservation.token == token else { throw Failure.staleScope }
        guard phase != .retired else { throw Failure.inactive }
        guard !reservation.claimed else { throw Failure.busy }
        reservation.claimed = true; work = reservation
        let current = reservation
        return try await withTaskCancellationHandler {
            let outcome = await current.task.value
            do {
                try Task.checkCancellation()
                guard phase != .retired, work?.token == token else { throw Failure.inactive }
                let rows: [LiveDiarizationFrame]
                switch outcome {
                case .prepared(let owner):
                    guard current.kind == .preparation else { throw Failure.failed }
                    resources = owner; phase = .active; rows = []
                case .produced(let chunks):
                    rows = try timeline.map(chunks, terminal: current.kind == .finish)
                    if current.kind == .finish { phase = .finished }
                case .failed: throw Failure.failed
                }
                let batch = LiveDiarizationBatch(token: token, frames: rows, streamSampleEnd: timeline.streamEnd,
                    nativeFrameEnd: timeline.frameEnd, replay: false)
                if current.kind == .finish {
                    terminal = .init(token: token, frames: [], streamSampleEnd: batch.streamSampleEnd, nativeFrameEnd: batch.nativeFrameEnd, replay: true)
                }
                work = nil
                return batch
            } catch { retire(); throw error }
        } onCancel: {
            current.task.cancel()
            Task { await self.retire() }
        }
    }

    func finish(scope: LiveLaneScope) async throws -> LiveDiarizationBatch {
        try Task.checkCancellation()
        guard scope == timeline.scope else { throw Failure.staleScope }
        if phase == .finished, let terminal { return terminal }
        guard phase == .active || phase == .paused, let resources else { throw Failure.inactive }
        guard work == nil else { throw Failure.busy }
        let token = token()
        let task = Task {
            defer { withExtendedLifetime(resources) {} }
            do { try Task.checkCancellation(); return Outcome.produced(try await resources.driver.finish()) }
            catch { return Outcome.failed }
        }
        work = .init(token: token, kind: .finish, task: task, witness: resources.witness, resources: resources)
        return try await complete(token)
    }
    func utteranceBoundary(scope: LiveLaneScope) throws -> UUID {
        guard scope == timeline.scope else { throw Failure.staleScope }
        guard phase == .active else { throw Failure.inactive }
        return contextID
    }
    func pause(scope: LiveLaneScope) throws -> UUID {
        guard scope == timeline.scope else { throw Failure.staleScope }
        guard phase == .active else { throw Failure.inactive }
        guard work == nil else { throw Failure.busy }
        phase = .paused; return contextID
    }
    func resume(previous: LiveLaneScope, next: LiveLaneScope) throws -> UUID {
        guard phase == .paused else { throw Failure.inactive }
        do { try timeline.resume(previous: previous, next: next) }
        catch Failure.capacity { retire(); throw Failure.capacity }
        phase = .active; return contextID
    }
    func attachingContext(to segment: CommittedLiveSegment, scope: LiveLaneScope) throws -> CommittedLiveSegment {
        guard phase == .active || phase == .paused || phase == .finished else { throw Failure.inactive }
        return try timeline.attaching(segment, scope: scope)
    }
    func retire() {
        guard phase != .retired else { return }
        phase = .retired; factory = nil; terminal = nil; work?.task.cancel()
    }

    /// Joins actual work even if the caller is canceled. Shutdown never competes
    /// with native input and is invoked once; the retired session may stay alive.
    func joinRetirement() async {
        guard phase == .retired, !joined else { return }
        let operation: (UUID, Task<Void, Never>)
        if let retirement { operation = retirement }
        else {
            let current = work, owner = resources, witness = witness
            let task = Task {
                var returned: Resources?
                if let current, case .prepared(let prepared) = await current.task.value { returned = prepared }
                if let actual = owner ?? returned { await actual.driver.shutdown() }
                withExtendedLifetime(current) {}; withExtendedLifetime(owner) {}; withExtendedLifetime(returned) {}; withExtendedLifetime(witness) {}
            }
            operation = (UUID(), task); retirement = operation
        }
        await operation.1.value
        if retirement?.0 == operation.0 {
            work = nil; resources = nil; witness = nil; retirement = nil; joined = true
        }
    }
}
