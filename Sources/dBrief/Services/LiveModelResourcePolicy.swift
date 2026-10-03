import Foundation
import dBriefWire

struct LiveResourceProfile: Sendable, Equatable {
    let id: String
    let hardware: String
    let modelRevision: String
    let chunkMs: Int
    let sourceCount: Int
    let qualificationID: String
    let asrBytes: UInt64
    let attributionBytes: UInt64?
    let headroomBytes: UInt64
    let concurrentChatModels: [String: UInt64]
    let backgroundWorkQualified: Bool
    let vad: LiveVADIdentity?
    /// Qualified total peak cost at this exact source count, including shared
    /// allocation and every source's native manager/scratch. Never an estimate.
    let vadBytes: UInt64?
    let asr: LiveASRIdentity?
    init(id: String, hardware: String, modelRevision: String, chunkMs: Int, sourceCount: Int,
         qualificationID: String, asrBytes: UInt64, attributionBytes: UInt64?, headroomBytes: UInt64,
         concurrentChatModels: [String: UInt64], backgroundWorkQualified: Bool,
         vad: LiveVADIdentity? = nil, vadBytes: UInt64? = nil, asr: LiveASRIdentity? = nil) {
        self.id = id; self.hardware = hardware; self.modelRevision = modelRevision; self.chunkMs = chunkMs
        self.sourceCount = sourceCount; self.qualificationID = qualificationID; self.asrBytes = asrBytes
        self.attributionBytes = attributionBytes; self.headroomBytes = headroomBytes
        self.concurrentChatModels = concurrentChatModels; self.backgroundWorkQualified = backgroundWorkQualified
        self.vad = vad; self.vadBytes = vadBytes
        self.asr = asr
    }
}
struct LiveResourceRequest: Sendable, Equatable {
    let profileID: String
    let hardware: String
    let modelRevision: String
    let chunkMs: Int
    let sourceCount: Int
    let attributionRequested: Bool
    let vad: LiveVADConfiguration?
    let asr: LiveASRIdentity?
    init(profileID: String, hardware: String, modelRevision: String, chunkMs: Int, sourceCount: Int,
         attributionRequested: Bool, vad: LiveVADConfiguration? = nil, asr: LiveASRIdentity? = nil) {
        self.profileID = profileID; self.hardware = hardware; self.modelRevision = modelRevision
        self.chunkMs = chunkMs; self.sourceCount = sourceCount; self.attributionRequested = attributionRequested; self.vad = vad
        self.asr = asr
    }
}
struct LiveResourceMeasurement: Sendable {
    enum Pressure: Sendable { case normal, warning, critical }
    let availableBytes: UInt64
    let pressure: Pressure
}
enum LiveResourceRejection: Error, Equatable { case unsupported, invalidProfile, insufficientMemory, pressure, ownerConflict, configurationChanged, busy, measurementChanged }
/// An async memory sample is meaningful only while allocation/residency state
/// remains the same. Values from another policy cannot certify this owner.
struct LiveResourceMeasurementToken: Sendable, Equatable {
    fileprivate let policyID: UUID
    fileprivate let generation: UUID
}
struct LiveResourceLease: Sendable, Equatable {
    let id: UUID
    let identity: LiveSessionIdentity
    let request: LiveResourceRequest
    let attributionEnabled: Bool
    let reservedBytes: UInt64
}
enum LiveResourceJob: Sendable, Equatable { case localChat(model: String), background(model: String), externallyManagedCLI, configuredRemote }
struct LiveResourceJobLease: Sendable, Equatable {
    let id: UUID
    let owner: UUID
    let job: LiveResourceJob
    let reservedBytes: UInt64
}
enum LiveResourceJobDecision: Sendable, Equatable { case admitted, deferred }
struct LiveResourcePressureActions: Sendable, Equatable {
    let deferLocalChat: Bool
    let deferBackground: Bool
    let retireAttribution: Set<UUID>
}

/// Profiles are measurements for exact hardware/model/chunk/source combinations,
/// never a parameter-count estimate. Production starts with no eligible profiles.
/// availableBytes is current available memory; chat is an additional allocation.
actor LiveModelResourcePolicy {
    private struct Reservation {
        let lease: LiveResourceLease
        let profile: LiveResourceProfile
        let exclusive: Bool
        var attributionRunning: Bool
        var attributionResident = false
        var resident = false
        var vadResident = false
        // All sums are validated against the profile's maximum allocation
        // before Reservation exists. VAD stays charged until helper teardown.
        var mandatoryBytes: UInt64 { profile.asrBytes + (profile.vadBytes ?? 0) }
        var bytes: UInt64 { mandatoryBytes + (attributionRunning ? profile.attributionBytes ?? 0 : 0) }
        var pendingOptionalBytes: UInt64 {
            (vadResident ? 0 : profile.vadBytes ?? 0) +
                (attributionRunning && !attributionResident ? profile.attributionBytes ?? 0 : 0)
        }
    }
    private let profiles: [String: [LiveResourceProfile]]
    private let policyID = UUID()
    private var generation = UUID() {
        didSet { for continuation in updateContinuations.values { continuation.yield(()) } }
    }
    private var updateContinuations: [UUID:AsyncStream<Void>.Continuation] = [:]
    private var active: Reservation?
    private struct JobReservation { let lease: LiveResourceJobLease; var resident = false }
    private var jobs: [UUID: JobReservation] = [:]

    init(profiles: [LiveResourceProfile] = []) {
        self.profiles = Dictionary(grouping: profiles,by: \.id)
    }

    func admit(identity: LiveSessionIdentity, request: LiveResourceRequest, measurement: LiveResourceMeasurement) throws -> LiveResourceLease {
        if let active {
            guard !active.exclusive else { throw LiveResourceRejection.busy }
            if active.lease.identity == identity {
                guard active.lease.request == request else { throw LiveResourceRejection.configurationChanged }
                return active.lease
            }
            if active.lease.identity.recordingID == identity.recordingID || active.lease.identity.captureSessionID == identity.captureSessionID {
                throw LiveResourceRejection.ownerConflict
            }
            // A profile qualifies one capture, not two simultaneous live models.
            throw LiveResourceRejection.busy
        }
        return try createReservation(identity: identity,request: request,measurement: measurement,exclusive: false)
    }

    // Profiles are immutable for this policy's lifetime. A false result cannot
    // race future eligible live admission in the same app owner.
    var hasProfiles: Bool { !profiles.isEmpty }
    var hasCaptureReservation: Bool { active != nil }
    var jobCount: Int { jobs.count }
    func measurementDidChange() { generation = UUID() }
    func updates(since token: LiveResourceMeasurementToken) -> AsyncStream<Void> {
        let (stream,continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard updateContinuations.count < 128, token.policyID == policyID else { continuation.finish(); return stream }
        let id = UUID(); updateContinuations[id] = continuation
        continuation.onTermination = { @Sendable _ in Task { await self.removeUpdate(id) } }
        if token.generation != generation { continuation.yield(()) }
        return stream
    }
    private func removeUpdate(_ id: UUID) { updateContinuations[id] = nil }
    func reserveJob(owner: UUID,job: LiveResourceJob,measurement: LiveResourceMeasurement,
                    token: LiveResourceMeasurementToken) throws -> LiveResourceJobLease? {
        try validateToken(token)
        return reserveJob(owner: owner,job: job,measurement: measurement)
    }

    func measurementToken() -> LiveResourceMeasurementToken { .init(policyID: policyID,generation: generation) }

    /// Preparation receives a new exclusive receipt. Neither a duplicate
    /// preparation nor the legacy idempotent API may borrow it.
    func admitNew(identity: LiveSessionIdentity, request: LiveResourceRequest, measurement: LiveResourceMeasurement,
                  token: LiveResourceMeasurementToken) throws -> LiveResourceLease {
        guard active == nil else { throw LiveResourceRejection.busy }
        try validateToken(token)
        return try createReservation(identity: identity,request: request,measurement: measurement,exclusive: true)
    }

    private func createReservation(identity: LiveSessionIdentity, request: LiveResourceRequest,
                                   measurement: LiveResourceMeasurement, exclusive: Bool) throws -> LiveResourceLease {
        let profile = try profile(matching: request)
        // A job already queued before capture may not have allocated yet. Its
        // cost must fit as well, and the combined model must be qualified.
        let pendingJobBytes = try pendingJobBytes(profile)
        guard measurement.pressure != .critical else { throw LiveResourceRejection.pressure }
        let mandatory = profile.asrBytes + (profile.vadBytes ?? 0)
        let required = mandatory.addingReportingOverflow(pendingJobBytes)
        guard !required.overflow, Self.fits(required.partialValue,headroom: profile.headroomBytes,available: measurement.availableBytes) else {
            throw LiveResourceRejection.insufficientMemory
        }
        let attribution = request.attributionRequested && measurement.pressure == .normal && profile.attributionBytes.map {
            let total = required.partialValue.addingReportingOverflow($0)
            return !total.overflow && Self.fits(total.partialValue,headroom: profile.headroomBytes,available: measurement.availableBytes)
        } == true
        let reserved = mandatory + (attribution ? profile.attributionBytes! : 0)
        let lease = LiveResourceLease(id: UUID(),identity: identity,request: request,attributionEnabled: attribution,reservedBytes: reserved)
        active = .init(lease: lease,profile: profile,exclusive: exclusive,attributionRunning: attribution)
        generation = UUID()
        return lease
    }

    /// Read-only shape/identity gate before cache copying. It grants no lease,
    /// residency or memory authority; admission still samples current memory.
    func validateProfile(_ request: LiveResourceRequest) throws { _ = try profile(matching: request) }

    private func profile(matching request: LiveResourceRequest) throws -> LiveResourceProfile {
        guard let candidates = profiles[request.profileID] else { throw LiveResourceRejection.unsupported }
        guard candidates.count == 1, let profile = candidates.first, Self.valid(profile) else { throw LiveResourceRejection.invalidProfile }
        guard profile.hardware == request.hardware, profile.modelRevision == request.modelRevision,
              profile.chunkMs == request.chunkMs, profile.sourceCount == request.sourceCount,
              profile.vad == request.vad?.identity, request.vad?.isValid ?? true,
              profile.asr == request.asr, request.asr?.isSupported ?? true else { throw LiveResourceRejection.unsupported }
        return profile
    }

    /// Revalidation grants no residency or resource-release authority. A job
    /// allocated during sampling invalidates the token, rather than appearing
    /// resident in memory telemetry captured before its allocation.
    func validatePreparedStart(_ lease: LiveResourceLease, measurement: LiveResourceMeasurement,
                               token: LiveResourceMeasurementToken) throws {
        guard let active, active.lease == lease, active.exclusive else { throw LiveResourceRejection.ownerConflict }
        try validateToken(token)
        guard !active.resident, !active.vadResident, !active.attributionResident else { throw LiveResourceRejection.configurationChanged }
        guard measurement.pressure != .critical,
              measurement.pressure == .normal || !active.attributionRunning else { throw LiveResourceRejection.pressure }
        let required = active.bytes.addingReportingOverflow(try pendingJobBytes(active.profile))
        guard !required.overflow, Self.fits(required.partialValue,headroom: active.profile.headroomBytes,available: measurement.availableBytes) else {
            throw LiveResourceRejection.insufficientMemory
        }
    }

    private func validateToken(_ token: LiveResourceMeasurementToken) throws {
        guard token.policyID == policyID, token.generation == generation else { throw LiveResourceRejection.measurementChanged }
    }

    private func pendingJobBytes(_ profile: LiveResourceProfile) throws -> UInt64 {
        guard jobs.count <= 1 else { throw LiveResourceRejection.busy }
        guard let job = jobs.values.first else { return 0 }
        let model: String
        switch job.lease.job {
        case .localChat(let value): model = value
        case .background(let value):
            guard profile.backgroundWorkQualified else { throw LiveResourceRejection.busy }
            model = value
        case .externallyManagedCLI, .configuredRemote: throw LiveResourceRejection.busy
        }
        guard let cost = profile.concurrentChatModels[model] else { throw LiveResourceRejection.busy }
        return job.resident ? 0 : max(cost,job.lease.reservedBytes)
    }

    /// Exact receipts prevent a stale owner or forged lease from releasing a
    /// replacement's reservation. Release follows actual child teardown.
    func release(_ lease: LiveResourceLease) {
        guard active?.lease == lease else { return }
        active = nil
        generation = UUID()
    }

    /// Value-shaped receipts from another policy, retired owners or constructed
    /// leases cannot authorize a configured native consumer.
    func validateActiveLease(_ lease: LiveResourceLease) -> Bool { active?.lease == lease }

    /// ASR readiness confirms only its own allocation in current telemetry.
    /// An enabled but unallocated attribution model keeps its pending charge.
    func confirmResident(_ lease: LiveResourceLease) {
        guard active?.lease == lease, active?.resident == false else { return }
        active?.resident = true
        generation = UUID()
    }

    /// Only actual VAD model/manager loading can certify its allocation. ASR
    /// readiness is deliberately insufficient, including after degradation.
    func confirmVADResident(_ lease: LiveResourceLease) {
        guard active?.lease == lease, active?.profile.vad != nil, active?.vadResident == false else { return }
        active?.vadResident = true
        generation = UUID()
    }

    func confirmAttributionResident(_ lease: LiveResourceLease) {
        guard active?.lease == lease, active?.attributionRunning == true, active?.attributionResident == false else { return }
        active?.attributionResident = true
        generation = UUID()
    }

    /// A preview decision never reserves memory. Execution uses this atomic
    /// permit; one local job is qualified alongside live ASR. Remote routing is
    /// still selected by the caller and never substituted by resource pressure.
    func reserveJob(owner: UUID, job: LiveResourceJob, measurement: LiveResourceMeasurement) -> LiveResourceJobLease? {
        if let known = jobs[owner] { return known.lease.job == job ? known.lease : nil }
        if case .configuredRemote = job { return .init(id: UUID(),owner: owner,job: job,reservedBytes: 0) }
        guard jobs.count < 128, decide(job,measurement: measurement) == .admitted else { return nil }
        var bytes: UInt64 = 0
        if let active {
            switch job {
            case .localChat(let model), .background(let model): bytes = active.profile.concurrentChatModels[model]!
            case .externallyManagedCLI, .configuredRemote: break
            }
        }
        let lease = LiveResourceJobLease(id: UUID(),owner: owner,job: job,reservedBytes: bytes)
        jobs[owner] = .init(lease: lease)
        generation = UUID()
        return lease
    }

    func confirmJobResident(_ lease: LiveResourceJobLease) {
        guard jobs[lease.owner]?.lease == lease, jobs[lease.owner]?.resident == false else { return }
        jobs[lease.owner]?.resident = true
        generation = UUID()
    }

    func releaseJob(_ lease: LiveResourceJobLease) {
        guard jobs[lease.owner]?.lease == lease else { return }
        jobs[lease.owner] = nil
        generation = UUID()
    }

    func decide(_ job: LiveResourceJob, measurement: LiveResourceMeasurement) -> LiveResourceJobDecision {
        if case .configuredRemote = job { return .admitted }
        guard let active else { return .admitted } // Preserve the ordinary baseline.
        guard active.resident, jobs.isEmpty, measurement.pressure == .normal else { return .deferred }
        let model: String
        switch job {
        case .localChat(let value): model = value
        case .background(let value):
            guard active.profile.backgroundWorkQualified else { return .deferred }
            model = value
        case .externallyManagedCLI: return .deferred
        case .configuredRemote: return .admitted
        }
        guard let extra = active.profile.concurrentChatModels[model] else { return .deferred }
        let allocation = extra.addingReportingOverflow(active.pendingOptionalBytes)
        guard !allocation.overflow,
              Self.fits(allocation.partialValue,headroom: active.profile.headroomBytes,available: measurement.availableBytes) else { return .deferred }
        return .admitted
    }

    /// Keeping viable ASR is deliberate; the capture owner records module loss
    /// after optional attribution actually retires. No route substitution occurs.
    func pressureActions(_ measurement: LiveResourceMeasurement) -> LiveResourcePressureActions {
        guard let active else { return .init(deferLocalChat: false,deferBackground: false,retireAttribution: []) }
        let constrained = measurement.pressure != .normal || measurement.availableBytes < active.profile.headroomBytes
        return .init(deferLocalChat: constrained,deferBackground: constrained,
            retireAttribution: constrained && active.attributionRunning ? [active.lease.id] : [])
    }

    func confirmAttributionRetired(_ lease: LiveResourceLease) {
        guard active?.lease == lease, active?.attributionRunning == true else { return }
        active?.attributionRunning = false
        generation = UUID()
    }

    var reservedBytes: UInt64 { active?.bytes ?? 0 }

    private static func fits(_ bytes: UInt64, headroom: UInt64, available: UInt64) -> Bool {
        let sum = bytes.addingReportingOverflow(headroom)
        return !sum.overflow && sum.partialValue <= available
    }

    private static func valid(_ profile: LiveResourceProfile) -> Bool {
        func validID(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 512 && !text.contains("\0") }
        guard validID(profile.id), validID(profile.hardware), validID(profile.modelRevision), validID(profile.qualificationID),
              [560,1120,2240].contains(profile.chunkMs), (1...2).contains(profile.sourceCount), profile.asrBytes > 0,
              (profile.vad == nil) == (profile.vadBytes == nil),
              profile.concurrentChatModels.count <= 64 else { return false }
        if let vad = profile.vad { guard vad.isValid, (profile.vadBytes ?? 0) > 0 else { return false } }
        if let asr = profile.asr { guard asr.isSupported, asr.modelRevision == profile.modelRevision else { return false } }
        guard let mandatory = sum(profile.asrBytes,profile.vadBytes ?? 0),
              sum(mandatory,profile.headroomBytes) != nil else { return false }
        if let extra = profile.attributionBytes {
            guard extra > 0, sum(mandatory,extra,profile.headroomBytes) != nil else { return false }
        }
        guard let maximum = sum(mandatory,profile.attributionBytes ?? 0) else { return false }
        return profile.concurrentChatModels.allSatisfy {
            validID($0.key) && $0.value > 0 && sum(maximum,$0.value,profile.headroomBytes) != nil
        }
    }

    private static func sum(_ values: UInt64...) -> UInt64? {
        var total: UInt64 = 0
        for value in values {
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }
}
