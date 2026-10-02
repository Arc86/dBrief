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
}
struct LiveResourceRequest: Sendable, Equatable {
    let profileID: String
    let hardware: String
    let modelRevision: String
    let chunkMs: Int
    let sourceCount: Int
    let attributionRequested: Bool
}
struct LiveResourceMeasurement: Sendable {
    enum Pressure: Sendable { case normal, warning, critical }
    let availableBytes: UInt64
    let pressure: Pressure
}
enum LiveResourceRejection: Error, Equatable { case unsupported, invalidProfile, insufficientMemory, pressure, ownerConflict, configurationChanged, busy }
struct LiveResourceLease: Sendable, Equatable {
    let id: UUID
    let identity: LiveSessionIdentity
    let request: LiveResourceRequest
    let attributionEnabled: Bool
    let reservedBytes: UInt64
}
enum LiveResourceJob: Sendable, Equatable { case localChat(model: String), background(model: String), configuredRemote }
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
        var attributionRunning: Bool
        var resident = false
        var bytes: UInt64 { profile.asrBytes + (attributionRunning ? profile.attributionBytes ?? 0 : 0) }
    }
    private let profiles: [String: [LiveResourceProfile]]
    private var active: Reservation?
    private struct JobReservation { let lease: LiveResourceJobLease; var resident = false }
    private var jobs: [UUID: JobReservation] = [:]

    init(profiles: [LiveResourceProfile] = []) {
        self.profiles = Dictionary(grouping: profiles,by: \.id)
    }

    func admit(identity: LiveSessionIdentity, request: LiveResourceRequest, measurement: LiveResourceMeasurement) throws -> LiveResourceLease {
        if let active {
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
        guard let candidates = profiles[request.profileID] else { throw LiveResourceRejection.unsupported }
        guard candidates.count == 1, let profile = candidates.first, Self.valid(profile) else { throw LiveResourceRejection.invalidProfile }
        guard profile.hardware == request.hardware, profile.modelRevision == request.modelRevision,
              profile.chunkMs == request.chunkMs, profile.sourceCount == request.sourceCount else { throw LiveResourceRejection.unsupported }
        // A job already queued before capture may not have allocated yet. Its
        // cost must fit as well, and the combined model must be qualified.
        guard jobs.count <= 1 else { throw LiveResourceRejection.busy }
        var pendingJobBytes: UInt64 = 0
        if let job = jobs.values.first {
            let model: String
            switch job.lease.job {
            case .localChat(let value): model = value
            case .background(let value):
                guard profile.backgroundWorkQualified else { throw LiveResourceRejection.busy }
                model = value
            case .configuredRemote: throw LiveResourceRejection.busy
            }
            guard let cost = profile.concurrentChatModels[model] else { throw LiveResourceRejection.busy }
            if !job.resident { pendingJobBytes = max(cost,job.lease.reservedBytes) }
        }
        guard measurement.pressure != .critical else { throw LiveResourceRejection.pressure }
        let required = profile.asrBytes.addingReportingOverflow(pendingJobBytes)
        guard !required.overflow, Self.fits(required.partialValue,headroom: profile.headroomBytes,available: measurement.availableBytes) else {
            throw LiveResourceRejection.insufficientMemory
        }
        let attribution = request.attributionRequested && measurement.pressure == .normal && profile.attributionBytes.map {
            let total = required.partialValue.addingReportingOverflow($0)
            return !total.overflow && Self.fits(total.partialValue,headroom: profile.headroomBytes,available: measurement.availableBytes)
        } == true
        let reserved = profile.asrBytes + (attribution ? profile.attributionBytes! : 0)
        let lease = LiveResourceLease(id: UUID(),identity: identity,request: request,attributionEnabled: attribution,reservedBytes: reserved)
        active = .init(lease: lease,profile: profile,attributionRunning: attribution)
        return lease
    }

    /// Exact receipts prevent a stale owner or forged lease from releasing a
    /// replacement's reservation. Release follows actual child teardown.
    func release(_ lease: LiveResourceLease) {
        guard active?.lease == lease else { return }
        active = nil
    }

    /// The helper's readiness receipt, not admission itself, confirms its model
    /// allocation is reflected in current available-memory telemetry.
    func confirmResident(_ lease: LiveResourceLease) {
        guard active?.lease == lease else { return }
        active?.resident = true
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
            case .configuredRemote: break
            }
        }
        let lease = LiveResourceJobLease(id: UUID(),owner: owner,job: job,reservedBytes: bytes)
        jobs[owner] = .init(lease: lease)
        return lease
    }

    func confirmJobResident(_ lease: LiveResourceJobLease) {
        guard jobs[lease.owner]?.lease == lease else { return }
        jobs[lease.owner]?.resident = true
    }

    func releaseJob(_ lease: LiveResourceJobLease) {
        guard jobs[lease.owner]?.lease == lease else { return }
        jobs[lease.owner] = nil
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
        case .configuredRemote: return .admitted
        }
        guard let extra = active.profile.concurrentChatModels[model],
              Self.fits(extra,headroom: active.profile.headroomBytes,available: measurement.availableBytes) else { return .deferred }
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
        guard active?.lease == lease else { return }
        active?.attributionRunning = false
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
              !profile.asrBytes.addingReportingOverflow(profile.headroomBytes).overflow,
              profile.concurrentChatModels.count <= 64 else { return false }
        if let extra = profile.attributionBytes {
            let total = profile.asrBytes.addingReportingOverflow(extra)
            guard extra > 0, !total.overflow, !total.partialValue.addingReportingOverflow(profile.headroomBytes).overflow else { return false }
        }
        let maximumASR = profile.asrBytes + (profile.attributionBytes ?? 0)
        return profile.concurrentChatModels.allSatisfy {
            let combined = maximumASR.addingReportingOverflow($0.value)
            return validID($0.key) && $0.value > 0 && !combined.overflow && !combined.partialValue.addingReportingOverflow(profile.headroomBytes).overflow
        }
    }
}
