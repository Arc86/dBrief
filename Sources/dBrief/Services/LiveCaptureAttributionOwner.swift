import Foundation
import dBriefWire

struct LiveAttributionHooks: Sendable {
    var afterRegistration: @Sendable (LiveLaneScope, UUID) async -> Void = { _,_ in }
    var beforeEvaluation: @Sendable () async -> Void = {}
}

/// Frozen capture-owned optional preparation. Cancellation seals publication;
/// actual original copy/open/evaluation return owns cleanup and payload release.
final class LiveCaptureAttributionOwner: @unchecked Sendable {
    let publication: LiveAttributionPublication
    let assets: LiveDiarizationModelAssets
    let admission: LiveModelJobAdmission
    let metadata: LiveDiarizationBegin
    private let hooks: LiveAttributionHooks
    private let reserve: @Sendable () async throws -> LiveRecordingPayloadBudget.Lease
    private let lock = NSLock()
    private var captureOwner: UUID?
    private var lease: LiveResourceLease?
    private var started = false, handedOff = false, stopIssued = false
    private var original: Task<Void,Never>?
    private var sealTransport: (@Sendable () async -> Void)?
    private var window: LiveAttributionWindow?
    private var working: LiveAttributionWorkingSet?
    private var fallbackReservation: LiveRecordingPayloadBudget.Lease?
    init(identity: LiveSessionIdentity, ownerID: UUID, assets: LiveDiarizationModelAssets,
         recording: RecordingDerivativeValidity, admission: LiveModelJobAdmission, hooks: LiveAttributionHooks,
         reserve: @escaping @Sendable () async throws -> LiveRecordingPayloadBudget.Lease) {
        publication = .init(identity: identity,ownerID: ownerID,recording: recording)
        self.assets = assets; self.admission = admission; self.hooks = hooks; self.reserve = reserve
        metadata = .init(ownerID: ownerID,configuration: assets.configuration)
    }
    func bind(to owner: UUID) -> Bool { lock.withLock {
        guard captureOwner == nil || captureOwner == owner, !started, assets.bind(to: publication.ownerID) else { return false }
        captureOwner = owner; return true
    } }
    func adopt(_ lease: LiveResourceLease, owner: UUID?) -> Bool { lock.withLock {
        guard captureOwner == owner, lease.identity == publication.identity,
              lease.request.attributionRequested, lease.request.diarization == assets.configuration.identity,
              self.lease == nil || self.lease == lease else { return false }
        self.lease = lease; return true
    } }
    var leaseID: UUID? { lock.withLock { lease?.id } }
    var posteriorCount: Int { lock.withLock { window }?.count ?? 0 }
    var workingBytes: Int { lock.withLock { working }?.chargedBytes ?? 0 }
    func seal() {
        publication.seal()
        let state = lock.withLock { () -> (Task<Void,Never>?, LiveAttributionWindow?, (@Sendable () async -> Void)?) in
            let stop = stopIssued ? nil : sealTransport; stopIssued = true
            return (original,window,stop)
        }
        state.1?.seal(); state.0?.cancel()
        if let stop = state.2 { Task { await stop() } }
    }
    /// Pending preflight has not started optional work. Resolve an unused exact
    /// optional reservation before a fresh mandatory start measurement/token.
    func retireUnstartedIfSealed() async {
        guard !publication.isActive, let lease = lock.withLock({ !started && !handedOff ? lease : nil }) else { return }
        await assets.retire(owner: publication.ownerID)?.value
        await admission.policy.confirmAttributionRetired(lease)
    }
    func start(transport: LiveASRTransport, scope: @escaping @Sendable () async -> LiveLaneScope?,
               receive: @escaping @Sendable (LiveDiarizationEvent) async -> Bool,
               publish: @escaping @Sendable (LiveSpeakerAttributor.Batch, UInt64) async -> LiveStoreAdmission) {
        guard publication.isActive else { return }
        guard let open = transport.openDiarization, let control = transport.diarizationControl,
              let retire = transport.sealDiarization else {
            seal();Task { await self.retireUnstartedIfSealed() };return
        }
        lock.withLock {
            guard !started, let lease, lease.attributionEnabled, publication.isActive else { return }
            started = true; sealTransport = retire
            original = Task { [self] in
                do {
                    let reservation = try await self.reserve()
                    let working = LiveAttributionWorkingSet(reservation)
                    self.lock.withLock { self.working = working; self.fallbackReservation = reservation }
                    try Task.checkCancellation(); guard self.publication.isActive else { throw CancellationError() }
                    try await self.assets.prepare(owner: self.publication.ownerID,captureInventoryLimit: 65_536)
                    try Task.checkCancellation(); guard self.publication.isActive else { throw CancellationError() }
                    // Once invoked, open may have claimed even if it later throws.
                    self.lock.withLock { self.handedOff = true }
                    let stream = try await open(self.assets,self.publication.ownerID,lease,self.admission,self.publication,working.reservation)
                    // Actual transport now pins this same reservation in native
                    // Payload. A possibly claimed throwing open retains fallback.
                    self.lock.withLock { self.fallbackReservation = nil }
                    guard self.publication.isActive, let current = await scope() else { throw CancellationError() }
                    guard try await control(.init(identity: self.publication.identity,ownerID: self.publication.ownerID,
                        payload: .prepare(epochID: current.epochID))) == .accepted else { throw LiveProtocolError.unavailable }
                    for try await event in stream {
                        guard self.publication.isActive, await receive(event) else { throw CancellationError() }
                        switch event.payload {
                        case .ready(_,let context):
                            let window = LiveAttributionWindow(working: working,publication: self.publication,context: context,
                                beforeEvaluation: self.hooks.beforeEvaluation,publish: publish,failed: { [weak self] in self?.seal() })
                            self.lock.withLock { self.window = window }
                            await self.hooks.afterRegistration(event.scope,context)
                            guard self.publication.isActive,
                                  try await control(.init(identity: self.publication.identity,ownerID: self.publication.ownerID,
                                    payload: .acknowledge(contextID: context))) == .accepted else { throw CancellationError() }
                        case .posterior(let context,_):
                            guard try await control(.init(identity: self.publication.identity,ownerID: self.publication.ownerID,
                                payload: .acknowledgePosterior(contextID: context,sequence: event.sequence))) == .accepted else { throw LiveProtocolError.unavailable }
                        case .retired: self.seal()
                        case .preparing: break
                        }
                    }
                } catch { self.seal() }
                let window = self.lock.withLock { self.window }
                await window?.finish()
                if !self.lock.withLock({ self.handedOff }) {
                    await self.assets.retire(owner: self.publication.ownerID)?.value
                    await self.admission.policy.confirmAttributionRetired(lease)
                    self.lock.withLock { self.fallbackReservation = nil }
                }
                self.lock.withLock { self.window = nil; self.working = nil }
            }
        }
    }
    func append(scope: LiveLaneScope, rows: [LiveDiarizationRow]) throws {
        guard let window = lock.withLock({ window }) else { throw LiveProtocolError.closed }
        try window.append(scope: scope,rows: rows)
    }
    func offer(_ segment: CommittedLiveSegment) {
        guard publication.isActive, segment.source == .system, segment.diarizerContextID != nil else { return }
        guard lock.withLock({ window })?.offer(segment) == true else { seal(); return }
    }
    /// Only the native capture owner calls this after actual child exit.
    func joinAfterExit() async {
        seal(); let task = lock.withLock { original }; await task?.value
        await assets.retire(owner: publication.ownerID)?.value
        lock.withLock { fallbackReservation = nil }
    }
}
