import Foundation
import Testing
import dBriefWire
@testable import dBrief

private struct ResourceFixture {
    let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
    var profile: LiveResourceProfile { .init(id: "fixture",hardware: "fixture-mac",modelRevision: "native-r1",chunkMs: 1120,sourceCount: 2,
        qualificationID: "deterministic-test-only",asrBytes: 400,attributionBytes: 200,headroomBytes: 100,
        concurrentChatModels: ["configured-model":300],backgroundWorkQualified: false) }
    func request(labels: Bool = false, chunk: Int = 1120) -> LiveResourceRequest {
        .init(profileID: "fixture",hardware: "fixture-mac",modelRevision: "native-r1",chunkMs: chunk,sourceCount: 2,attributionRequested: labels)
    }
    func measurement(_ available: UInt64 = 1000, pressure: LiveResourceMeasurement.Pressure = .normal) -> LiveResourceMeasurement {
        .init(availableBytes: available,pressure: pressure)
    }
}

@Suite struct LiveResourceAdmissionTests {
    @Test func unknownProfilesCannotEnableNativeAndBaselineJobsStayAvailable() async {
        let f = ResourceFixture(), policy = LiveModelResourcePolicy()
        await #expect(throws: LiveResourceRejection.unsupported) { try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement()) }
        #expect(await policy.decide(.localChat(model: "existing"),measurement: f.measurement()) == .admitted)
        #expect(await policy.reservedBytes == 0)
    }
    @Test func configurationAndQualificationAreExactAndReservationsAreIdempotent() async throws {
        let f = ResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile])
        await #expect(throws: LiveResourceRejection.unsupported) { try await policy.admit(identity: f.identity,request: f.request(chunk: 560),measurement: f.measurement()) }
        let lease = try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement())
        #expect(lease.reservedBytes == 400 && !lease.attributionEnabled)
        #expect(try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement(0,pressure: .critical)) == lease)
        await #expect(throws: LiveResourceRejection.configurationChanged) { try await policy.admit(identity: f.identity,request: f.request(labels: true),measurement: f.measurement()) }
        await #expect(throws: LiveResourceRejection.ownerConflict) {
            try await policy.admit(identity: .init(recordingID: f.identity.recordingID,captureSessionID: UUID()),request: f.request(),measurement: f.measurement())
        }
        #expect(await policy.reservedBytes == 400)
        await policy.release(lease); await policy.release(lease)
        #expect(await policy.reservedBytes == 0)
    }
    @Test func optionalAttributionCanBeRemovedWithoutDenyingViableASR() async throws {
        let f = ResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile])
        let lease = try await policy.admit(identity: f.identity,request: f.request(labels: true),measurement: f.measurement(550))
        #expect(!lease.attributionEnabled && lease.reservedBytes == 400)
        await policy.release(lease)
        await #expect(throws: LiveResourceRejection.insufficientMemory) { try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement(499)) }
        await #expect(throws: LiveResourceRejection.pressure) { try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement(1000,pressure: .critical)) }
    }
    @Test func chatUsesTheQualifiedConfiguredModelAndDoesNotChooseACloudFallback() async throws {
        let f = ResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile])
        let lease = try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement())
        await policy.confirmResident(lease)
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(400)) == .admitted)
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(399)) == .deferred)
        #expect(await policy.decide(.localChat(model: "different-model"),measurement: f.measurement()) == .deferred)
        #expect(await policy.decide(.background(model: "configured-model"),measurement: f.measurement()) == .deferred)
        #expect(await policy.decide(.configuredRemote,measurement: f.measurement(0,pressure: .critical)) == .admitted)
    }
    @Test func pressureRetiresOnlyOptionalAttributionAfterConfirmedTeardown() async throws {
        let f = ResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile])
        let lease = try await policy.admit(identity: f.identity,request: f.request(labels: true),measurement: f.measurement())
        #expect(lease.attributionEnabled && lease.reservedBytes == 600)
        let actions = await policy.pressureActions(f.measurement(10,pressure: .warning))
        #expect(actions.deferLocalChat && actions.deferBackground && actions.retireAttribution == [lease.id])
        #expect(await policy.reservedBytes == 600)
        await policy.confirmAttributionRetired(lease)
        #expect(await policy.reservedBytes == 400)
        #expect(await policy.pressureActions(f.measurement(10,pressure: .critical)).retireAttribution.isEmpty)
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(1000,pressure: .warning)) == .deferred)
    }
    @Test func invalidProfilesAndCounterOverflowCannotAdmit() async {
        let f = ResourceFixture()
        let invalid = LiveResourceProfile(id: "fixture",hardware: "fixture-mac",modelRevision: "native-r1",chunkMs: 1120,sourceCount: 2,
            qualificationID: "",asrBytes: .max,attributionBytes: .max,headroomBytes: .max,concurrentChatModels: [:],backgroundWorkQualified: false)
        let policy = LiveModelResourcePolicy(profiles: [invalid])
        await #expect(throws: LiveResourceRejection.invalidProfile) { try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement(.max)) }
        #expect(await policy.reservedBytes == 0)
    }
    @Test func anotherCaptureWaitsForTheExactOldLeaseToRelease() async throws {
        let f = ResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile])
        let first = try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement())
        let next = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
        await #expect(throws: LiveResourceRejection.busy) { try await policy.admit(identity: next,request: f.request(),measurement: f.measurement()) }
        let foreign = LiveResourceLease(id: first.id,identity: next,request: first.request,attributionEnabled: false,reservedBytes: first.reservedBytes)
        await policy.release(foreign); await policy.confirmAttributionRetired(foreign)
        #expect(await policy.reservedBytes == 400)
        await policy.release(first)
        let second = try await policy.admit(identity: next,request: f.request(),measurement: f.measurement())
        await policy.release(first)
        #expect(await policy.reservedBytes == second.reservedBytes && second.id != first.id)
    }

    @Test func preparationCannotSpendItsPromisedMemoryOnAChatJob() async throws {
        let f = ResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile])
        let lease = try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement(500))
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(500)) == .deferred)
        #expect(await policy.reserveJob(owner: UUID(),job: .localChat(model: "configured-model"),measurement: f.measurement(500)) == nil)
        let wrong = LiveResourceLease(id: UUID(),identity: lease.identity,request: lease.request,attributionEnabled: lease.attributionEnabled,reservedBytes: lease.reservedBytes)
        await policy.confirmResident(wrong)
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(1000)) == .deferred)
        await policy.confirmResident(lease)
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(400)) == .admitted)
    }
    @Test func concurrentLocalJobsCannotSpendTheSameHeadroom() async throws {
        let f = ResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile])
        let asr = try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement())
        await policy.confirmResident(asr)
        let owner = UUID()
        let job = try #require(await policy.reserveJob(owner: owner,job: .localChat(model: "configured-model"),measurement: f.measurement(400)))
        #expect(job.reservedBytes == 300)
        #expect(await policy.reserveJob(owner: owner,job: .localChat(model: "configured-model"),measurement: f.measurement(0)) == job)
        #expect(await policy.reserveJob(owner: UUID(),job: .localChat(model: "configured-model"),measurement: f.measurement(400)) == nil)
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(400)) == .deferred)
        await policy.releaseJob(.init(id: job.id,owner: UUID(),job: job.job,reservedBytes: job.reservedBytes))
        #expect(await policy.reserveJob(owner: UUID(),job: job.job,measurement: f.measurement(400)) == nil)
        await policy.release(asr) // Stop leaves the streaming answer's reservation alive.
        await policy.releaseJob(job)
        let next = try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement())
        await policy.confirmResident(next)
        #expect(await policy.reserveJob(owner: UUID(),job: job.job,measurement: f.measurement(400)) != nil)
    }
    @Test func aPreexistingJobNeedsQualifiedCombinedLoadAndPendingAllocationBudget() async throws {
        let f = ResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile]), owner = UUID()
        let job = try #require(await policy.reserveJob(owner: owner,job: .localChat(model: "configured-model"),measurement: f.measurement(1000)))
        await #expect(throws: LiveResourceRejection.insufficientMemory) { try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement(500)) }
        await policy.confirmJobResident(job)
        let asr = try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement(500))
        await policy.release(asr); await policy.releaseJob(job)
        _ = await policy.reserveJob(owner: UUID(),job: .localChat(model: "unsupported-model"),measurement: f.measurement())
        await #expect(throws: LiveResourceRejection.busy) { try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement()) }
    }

}
