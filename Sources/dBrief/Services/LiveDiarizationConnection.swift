import Foundation
import dBriefWire

/// Installed once. The reader never needs a mandatory-actor hop to decode an
/// optional body; it calls this separate recipient after its own bounded handoff.
final class LiveDiarizationEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LiveDiarizationConnection?
    func install(_ receiver: LiveDiarizationConnection) -> Bool { lock.withLock {
        guard value == nil else { return false }; value = receiver; return true
    } }
    var receiver: LiveDiarizationConnection? { lock.withLock { value } }
}

/// Native asset ownership is independent of stream/request lifetime. A stopped
/// helper cannot let a late policy claim or cancellation escape the original join.
private final class DiarizationNativeOwnership: @unchecked Sendable {
    private struct Payload: Sendable {
        let assets: LiveDiarizationModelAssets
        let snapshot: LiveDiarizationReadOnlySnapshot
        let assetOwner: UUID
        let lease: LiveResourceLease
        let admission: LiveModelJobAdmission
    }
    let transportOwner = UUID()
    private let lock = NSLock()
    private var payload: Payload?
    private var inputOpen = true
    private var claimed = false
    private var admissionPending = true
    private var admissionWaiter: CheckedContinuation<Void, Never>?
    private var cleanup: Task<Void, Never>?
    init(assets: LiveDiarizationModelAssets, snapshot: LiveDiarizationReadOnlySnapshot, owner: UUID,
         lease: LiveResourceLease, admission: LiveModelJobAdmission) {
        payload = .init(assets: assets, snapshot: snapshot, assetOwner: owner, lease: lease, admission: admission)
    }
    var inputAvailable: Bool { lock.withLock { inputOpen } }
    func validatePath() throws {
        let snapshot = lock.withLock { payload?.snapshot }
        guard let snapshot else { throw LiveProtocolError.closed }; _ = try snapshot.validateCurrentPath()
    }
    func markClaimed() { lock.withLock { claimed = true } }
    func admissionReturned() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard admissionPending else { return nil }; admissionPending = false
            let waiter = admissionWaiter; admissionWaiter = nil; return waiter
        }
        waiter?.resume()
    }
    func stopInput() { lock.withLock { inputOpen = false } }
    private func joinAdmission() async {
        await withCheckedContinuation { waiter in
            let immediate = lock.withLock { () -> Bool in
                if !admissionPending { return true }
                precondition(admissionWaiter == nil); admissionWaiter = waiter; return false
            }
            if immediate { waiter.resume() }
        }
    }
    /// Call only for an exact validated joined native receipt or actual child exit.
    func retireAfterProof() -> Task<Void, Never> { lock.withLock {
        inputOpen = false
        if let cleanup { return cleanup }
        let task = Task {
            await self.joinAdmission()
            let owned = self.lock.withLock { (self.payload, self.claimed) }
            if let payload = owned.0, owned.1 {
                await payload.assets.retire(owner: payload.assetOwner)?.value
                // Keep descriptors/snapshot through actual cleanup, not only Data.
                withExtendedLifetime(payload.snapshot) {}
                await payload.admission.policy.confirmAttributionRetired(payload.lease, transportOwner: self.transportOwner)
            }
            // An unclaimed/borrowed provisional snapshot cannot delete another
            // transport's root. Its existing asset owner remains responsible.
            self.lock.withLock { self.payload = nil }
        }
        cleanup = task; return task
    } }
}

/// Optional state, decoding, requests, deadlines and cleanup have no dependency
/// on the mandatory pending/event pipeline. Factory admission stays closed until
/// ordered store registration and annotation ownership are integrated.
actor LiveDiarizationConnection {
    nonisolated let epochs: LiveOptionalEpochAuthority
    private let identity: LiveSessionIdentity
    private let ownerID: UUID
    private let sessionRequestID: UUID
    private let writer: LivePipeWriter
    private let lease: LiveResourceLease
    private let admission: LiveModelJobAdmission
    private let native: DiarizationNativeOwnership
    private let afterClaim: (@Sendable () async -> Void)?
    private let stream: AsyncThrowingStream<LiveDiarizationEvent, Error>
    private let continuation: AsyncThrowingStream<LiveDiarizationEvent, Error>.Continuation
    private let encoder = JSONEncoder()
    private var admissionStarted = false, opened = false, prepareReserved = false, prepareSent = false
    private var publicationSealed = false, proofTrusted = true, preparingSeen = false, retired = false
    private var nextSequence: UInt64 = 0
    private var contextID: UUID?
    private var lastPosteriorSequence: UInt64?
    private var streamSampleEnd: Int64 = 0
    private var retireAttempted = false
    private struct Pending {
        let continuation: CheckedContinuation<LiveSessionReply, Error>
        let timer: Task<Void, Never>
    }
    private var pending: [UUID: Pending] = [:]
    var pendingCount: Int { pending.count }

    init(input: LiveSessionBegin, sessionRequestID: UUID, writer: LivePipeWriter,
         assets: LiveDiarizationModelAssets, snapshot: LiveDiarizationReadOnlySnapshot, ownerID: UUID,
         lease: LiveResourceLease, admission: LiveModelJobAdmission, epochAuthority: LiveOptionalEpochAuthority, afterClaim: (@Sendable () async -> Void)?) {
        identity = input.identity; self.ownerID = ownerID; self.sessionRequestID = sessionRequestID
        self.writer = writer; self.lease = lease; self.admission = admission; self.afterClaim = afterClaim
        epochs = epochAuthority
        native = .init(assets: assets, snapshot: snapshot, owner: ownerID, lease: lease, admission: admission)
        (stream, continuation) = AsyncThrowingStream<LiveDiarizationEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(4))
        continuation.onTermination = { @Sendable [weak self] termination in
            if case .cancelled = termination { Task { await self?.abandoned() } }
        }
    }

    func open() async throws -> AsyncThrowingStream<LiveDiarizationEvent, Error> {
        guard !admissionStarted else { throw LiveProtocolError.closed }
        admissionStarted = true
        defer { native.admissionReturned() }
        do {
            try Task.checkCancellation(); guard native.inputAvailable else { throw LiveProtocolError.closed }
            let token = await admission.policy.measurementToken()
            try Task.checkCancellation(); guard native.inputAvailable else { throw LiveProtocolError.closed }
            let measurement = try await admission.measurement()
            try Task.checkCancellation(); guard native.inputAvailable else { throw LiveProtocolError.closed }
            try native.validatePath()
            try await admission.policy.claimAttributionTransport(lease, owner: native.transportOwner, measurement: measurement, token: token)
            native.markClaimed()
            if let afterClaim { await afterClaim() }
            try Task.checkCancellation(); guard native.inputAvailable else { throw LiveProtocolError.closed }
            try native.validatePath()
            opened = true; return stream
        } catch {
            fail(error, invalidateProof: true, requestRetire: false); throw error
        }
    }

    func command(_ control: LiveDiarizationControl, deadline: Duration) async throws -> LiveSessionReply {
        try Task.checkCancellation()
        guard deadline > .zero, deadline <= .seconds(3), opened, native.inputAvailable, !retired,
              control.identity == identity, control.ownerID == ownerID else { throw LiveProtocolError.staleScope }
        let isRetire: Bool = if case .retire = control.payload { true } else { false }
        guard !publicationSealed || isRetire else { throw LiveProtocolError.closed }
        switch control.payload {
        case .prepare(let epoch):
            guard !prepareReserved, !prepareSent, epochs.isCurrent(epoch) else { throw LiveProtocolError.staleScope }
            // Reserve before the policy actor hop: concurrent callers must never
            // dispatch a second native Prepare while this validation is held.
            prepareReserved = true
            do {
                guard await admission.policy.validateAttributionTransport(lease, owner: native.transportOwner), native.inputAvailable,
                      !publicationSealed else { throw LiveProtocolError.closed }
                guard epochs.isCurrent(epoch) else { throw LiveProtocolError.staleScope }
                try Task.checkCancellation(); try native.validatePath()
            } catch {
                fail(error, invalidateProof: false, requestRetire: false); throw error
            }
        case .acknowledge(let context):
            guard preparingSeen, contextID == context else { throw LiveProtocolError.staleScope }
        case .acknowledgePosterior(let context, let sequence):
            guard contextID == context, lastPosteriorSequence == sequence else { throw LiveProtocolError.staleScope }
        case .retire:
            guard prepareSent else { throw LiveProtocolError.staleScope }
        }
        guard pending.count < 4 else {
            fail(LiveProtocolError.outputLimit, invalidateProof: false, requestRetire: true); throw LiveProtocolError.outputLimit
        }
        let id = UUID(), body = try encoder.encode(RequestEnvelope(id: id, request: .live(.diarizationControl(control))))
        guard body.count <= LiveOutputDemultiplexer.maximumOptionalBodyBytes else { throw LiveProtocolError.oversizedFrame }
        let frame = FrameCodec.encode(body)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: deadline) } catch { return }
                    await self?.expire(id)
                }
                pending[id] = .init(continuation: continuation, timer: timer)
                guard writer.tryWriteOptional(frame) else {
                    settle(id, error: LiveProtocolError.unavailable)
                    fail(LiveProtocolError.unavailable, invalidateProof: false, requestRetire: false); return
                }
                if case .prepare = control.payload { prepareSent = true }
                if isRetire { retireAttempted = true }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    /// Called only by the single separately owned optional ingest task.
    func receive(_ envelope: EventEnvelope) async {
        guard envelope.channel == .live else { malformed(); return }
        switch envelope.event {
        case .live(.reply(let reply)):
            guard let receipt = pending.removeValue(forKey: envelope.id) else { return } // Late/unknown IDs need no tombstones.
            receipt.timer.cancel(); receipt.continuation.resume(returning: reply)
            if case .rejected = reply { fail(LiveProtocolError.unavailable, invalidateProof: false, requestRetire: true) }
        case .live(.event(.diarization(let event))):
            guard proofTrusted, !retired else { return }
            guard envelope.id == sessionRequestID, prepareSent, event.ownerID == ownerID,
                  event.scope.identity == identity, event.scope.source == .system,
                  event.sequence == nextSequence, event.sequence < .max else { malformed(); return }
            // This await belongs only to the optional consumer. The held raw
            // receipt remains charged; mandatory accepted/rejected reply is free.
            guard await epochs.awaitAcceptance(event.scope.epochID), proofTrusted, native.inputAvailable else {
                fail(LiveProtocolError.staleScope, invalidateProof: true, requestRetire: true); return
            }
            nextSequence += 1
            switch event.payload {
            case .preparing:
                guard event.sequence == 0, !preparingSeen, contextID == nil else { malformed(); return }
                preparingSeen = true
            case .ready(let origin, let context):
                guard preparingSeen, contextID == nil, origin >= 0 else { malformed(); return }
                contextID = context
                await admission.policy.confirmAttributionResident(lease, transportOwner: native.transportOwner)
            case .posterior(let context, let rows):
                guard contextID == context, (1...2).contains(rows.count), rows.allSatisfy(\.isValid) else { malformed(); return }
                for row in rows {
                    guard row.streamSamples.start >= streamSampleEnd else { malformed(); return }
                    streamSampleEnd = row.streamSamples.end
                }
                lastPosteriorSequence = event.sequence
            case .retired(let context, _, _):
                guard preparingSeen, context == contextID else { malformed(); return }
                retired = true
                _ = native.retireAfterProof()
            }
            if !publicationSealed {
                if case .dropped = continuation.yield(event) {
                    fail(LiveProtocolError.outputLimit, invalidateProof: false, requestRetire: true)
                }
            }
            if retired { publicationSealed = true; continuation.finish() }
        default: malformed()
        }
    }
    func malformed() { fail(LiveProtocolError.invalidPacket, invalidateProof: true, requestRetire: true) }
    func rawOverflow() { fail(LiveProtocolError.outputLimit, invalidateProof: true, requestRetire: true) }
    private func abandoned() { fail(LiveProtocolError.closed, invalidateProof: false, requestRetire: true) }
    private func expire(_ id: UUID) {
        guard pending[id] != nil else { return }
        settle(id, error: MLHostError.liveDeadline)
        fail(MLHostError.liveDeadline, invalidateProof: false, requestRetire: true)
    }
    private func cancel(_ id: UUID) {
        guard pending[id] != nil else { return }
        settle(id, error: CancellationError())
        fail(CancellationError(), invalidateProof: false, requestRetire: true)
    }
    private func settle(_ id: UUID, error: any Error) {
        guard let receipt = pending.removeValue(forKey: id) else { return }
        receipt.timer.cancel(); receipt.continuation.resume(throwing: error)
    }
    private func fail(_ error: any Error, invalidateProof: Bool, requestRetire: Bool) {
        if invalidateProof { proofTrusted = false; epochs.close() }
        publicationSealed = true; continuation.finish(throwing: error)
        let held = pending; pending.removeAll()
        for receipt in held.values { receipt.timer.cancel(); receipt.continuation.resume(throwing: error) }
        if requestRetire { bestEffortRetire() }
    }
    private func bestEffortRetire() {
        guard prepareSent, !retireAttempted, !retired, native.inputAvailable else { return }
        retireAttempted = true
        let control = LiveDiarizationControl(identity: identity, ownerID: ownerID, payload: .retire)
        if let body = try? encoder.encode(RequestEnvelope(id: UUID(), request: .live(.diarizationControl(control)))),
           body.count <= LiveOutputDemultiplexer.maximumOptionalBodyBytes { _ = writer.tryWriteOptional(FrameCodec.encode(body)) }
    }
    /// Synchronous seal prevents controls across mandatory transport closure.
    nonisolated func transportEnded() { native.stopInput(); epochs.close() }
    func finishTransport() { fail(MLHostError.helperCrashed, invalidateProof: true, requestRetire: false) }
    func helperExited() async {
        transportEnded(); finishTransport()
        await native.retireAfterProof().value
    }
}
