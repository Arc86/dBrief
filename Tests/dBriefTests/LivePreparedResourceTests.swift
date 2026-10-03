import Foundation
import Testing
import dBriefWire
@testable import dBrief

private struct PreparedResourceFixture {
    let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
    let vad = LiveVADConfiguration(identity: .init(modelRevision: "fixture-vad",modelFingerprint: String(repeating: "a",count: 64),
        runtimeRevision: "21493f8dac5a97e65742e6ff26f42f164c2fda0f"),modelPath: "/fixture/vad.mlmodelc")
    func profile(vadEnabled: Bool = false) -> LiveResourceProfile {
        .init(id: "prepared",hardware: "fixture-mac",modelRevision: "fixture-asr",chunkMs: 1120,sourceCount: 2,
            qualificationID: "test-only",asrBytes: 500,attributionBytes: 200,headroomBytes: 100,
            concurrentChatModels: ["chat":600],backgroundWorkQualified: false,
            vad: vadEnabled ? vad.identity : nil,vadBytes: vadEnabled ? 120 : nil)
    }
    func request(vadEnabled: Bool = false) -> LiveResourceRequest {
        .init(profileID: "prepared",hardware: "fixture-mac",modelRevision: "fixture-asr",chunkMs: 1120,sourceCount: 2,
            attributionRequested: false,vad: vadEnabled ? vad : nil)
    }
    func memory(_ bytes: UInt64 = 2000, pressure: LiveResourceMeasurement.Pressure = .normal) -> LiveResourceMeasurement {
        .init(availableBytes: bytes,pressure: pressure)
    }
    func admit(_ policy: LiveModelResourcePolicy, vadEnabled: Bool = false) async throws -> LiveResourceLease {
        let token = await policy.measurementToken()
        return try await policy.admitNew(identity: identity,request: request(vadEnabled: vadEnabled),measurement: memory(),token: token)
    }
}

@Suite struct LivePreparedResourceTests {
    @Test func preparationCannotBorrowAnExistingLegacyLeaseAndLegacyIdempotenceSurvives() async throws {
        let f = PreparedResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile()])
        let old = try await policy.admit(identity: f.identity,request: f.request(),measurement: f.memory())
        let token = await policy.measurementToken()
        await #expect(throws: LiveResourceRejection.busy) {
            try await policy.admitNew(identity: f.identity,request: f.request(),measurement: f.memory(),token: token)
        }
        #expect(try await policy.admit(identity: f.identity,request: f.request(),measurement: f.memory(0,pressure: .critical)) == old)
        #expect(await policy.reservedBytes == 500)
    }

    @Test func legacyCannotBorrowAnExclusivePreparationReceiptInTheReverseDirection() async throws {
        let f = PreparedResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile()])
        let lease = try await f.admit(policy)
        await #expect(throws: LiveResourceRejection.busy) {
            try await policy.admit(identity: f.identity,request: f.request(),measurement: f.memory())
        }
        #expect(await policy.validateActiveLease(lease))
        #expect(await policy.reservedBytes == 500)
        await policy.release(lease)
        let next = try await policy.admit(identity: f.identity,request: f.request(),measurement: f.memory())
        #expect(next.id != lease.id)
        await policy.release(lease)
        #expect(await policy.validateActiveLease(next))
    }

    @Test func twoNewPreparationsCannotShareAnExactIdentityReceipt() async throws {
        let f = PreparedResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile()])
        let first = try await f.admit(policy)
        await #expect(throws: LiveResourceRejection.busy) { try await f.admit(policy) }
        #expect(await policy.validateActiveLease(first))
        #expect(await policy.reservedBytes == 500)
    }

    @Test func aPendingJobBecomingResidentInvalidatesTheEarlierMemorySample() async throws {
        let f = PreparedResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile()])
        let job = try #require(await policy.reserveJob(owner: UUID(),job: .localChat(model: "chat"),measurement: f.memory()))
        let lease = try await f.admit(policy)
        let sampledBeforeAllocation = await policy.measurementToken()
        let heldSample = f.memory(1000)
        await policy.confirmJobResident(job)
        // The old 1000-byte sample predates the job's 600-byte allocation.
        // Omitting that now-resident job would incorrectly admit ASR500+100.
        await #expect(throws: LiveResourceRejection.measurementChanged) {
            try await policy.validatePreparedStart(lease,measurement: heldSample,token: sampledBeforeAllocation)
        }
        let current = await policy.measurementToken()
        await #expect(throws: LiveResourceRejection.insufficientMemory) {
            try await policy.validatePreparedStart(lease,measurement: f.memory(400),token: current)
        }
        // A sample taken after residency already accounts for the job. Do not
        // charge its 600 bytes again: ASR500+headroom100 fit exactly.
        try await policy.validatePreparedStart(lease,measurement: f.memory(600),token: current)
        #expect(await policy.reservedBytes == 500)
    }

    @Test func samplingBeforeAJobReservationCannotAuthorizeNewAdmission() async throws {
        let f = PreparedResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile()])
        let token = await policy.measurementToken()
        _ = try #require(await policy.reserveJob(owner: UUID(),job: .localChat(model: "chat"),measurement: f.memory()))
        await #expect(throws: LiveResourceRejection.measurementChanged) {
            try await policy.admitNew(identity: f.identity,request: f.request(),measurement: f.memory(),token: token)
        }
        #expect(await policy.reservedBytes == 0)
    }

    @Test func finalValidationChargesPendingJobsAndVADWithoutMarkingReadiness() async throws {
        let f = PreparedResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile(vadEnabled: true)])
        let job = try #require(await policy.reserveJob(owner: UUID(),job: .localChat(model: "chat"),measurement: f.memory()))
        let lease = try await f.admit(policy,vadEnabled: true), token = await policy.measurementToken()
        // ASR500 + VAD120 + pendingChat600 + headroom100 = 1320.
        await #expect(throws: LiveResourceRejection.insufficientMemory) {
            try await policy.validatePreparedStart(lease,measurement: f.memory(1319),token: token)
        }
        try await policy.validatePreparedStart(lease,measurement: f.memory(1320),token: token)
        #expect(await policy.reservedBytes == 620)
        #expect(await policy.decide(.localChat(model: "chat"),measurement: f.memory()) == .deferred)
        await policy.releaseJob(job)
        let current = await policy.measurementToken()
        try await policy.validatePreparedStart(lease,measurement: f.memory(720),token: current)
        await #expect(throws: LiveResourceRejection.insufficientMemory) {
            try await policy.validatePreparedStart(lease,measurement: f.memory(719),token: current)
        }
    }

    @Test func pressureAndCurrentMemoryMustStillPermitTheExactUndispatchedLease() async throws {
        let f = PreparedResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile()])
        let lease = try await f.admit(policy), token = await policy.measurementToken()
        await #expect(throws: LiveResourceRejection.pressure) {
            try await policy.validatePreparedStart(lease,measurement: f.memory(2000,pressure: .critical),token: token)
        }
        await #expect(throws: LiveResourceRejection.insufficientMemory) {
            try await policy.validatePreparedStart(lease,measurement: f.memory(599),token: token)
        }
        try await policy.validatePreparedStart(lease,measurement: f.memory(600,pressure: .warning),token: token)
        await policy.confirmResident(lease)
        let resident = await policy.measurementToken()
        await #expect(throws: LiveResourceRejection.configurationChanged) {
            try await policy.validatePreparedStart(lease,measurement: f.memory(),token: resident)
        }
    }

    @Test func foreignTokensForgedReceiptsAndRetiredOwnersCannotAuthorizeDispatch() async throws {
        let f = PreparedResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile()])
        let other = LiveModelResourcePolicy(profiles: [f.profile()])
        let lease = try await f.admit(policy), token = await policy.measurementToken()
        let foreignToken = await other.measurementToken()
        await #expect(throws: LiveResourceRejection.measurementChanged) {
            try await policy.validatePreparedStart(lease,measurement: f.memory(),token: foreignToken)
        }
        let forged = LiveResourceLease(id: UUID(),identity: lease.identity,request: lease.request,
            attributionEnabled: lease.attributionEnabled,reservedBytes: lease.reservedBytes)
        await #expect(throws: LiveResourceRejection.ownerConflict) {
            try await policy.validatePreparedStart(forged,measurement: f.memory(),token: token)
        }
        await policy.release(forged); await policy.confirmResident(forged)
        try await policy.validatePreparedStart(lease,measurement: f.memory(600),token: token)
        await policy.release(lease)
        let fresh = await policy.measurementToken()
        await #expect(throws: LiveResourceRejection.ownerConflict) {
            try await policy.validatePreparedStart(lease,measurement: f.memory(),token: fresh)
        }
    }
}
