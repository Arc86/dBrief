import Foundation
import Testing
import dBriefWire
@testable import dBrief

private struct VADWireFixture {
    let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
    var begin: LiveSessionBegin { .init(identity: identity,
        configuration: .init(language: .auto,modelDirectory: "/fixture/asr"),epochs: [
            .init(id: UUID(),source: .microphone,engineRevision: "asr-r1",language: "auto",meetingOriginNanoseconds: nil)]) }
    var vad: [String: Any] { ["modelPath":"/fixture/silero.mlmodelc", "identity": [
        "modelRevision":"silero-r1", "modelFingerprint":String(repeating: "a",count: 64),
        "runtimeRevision":"21493f8dac5a97e65742e6ff26f42f164c2fda0f", "computeUnits":"cpuAndNeuralEngine",
        "positiveThreshold":0.85, "negativeThreshold":0.70, "minSilenceSamples":9600, "speechPaddingSamples":1600]] }
    func decode(_ vad: Any?) throws -> LiveSessionBegin {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(begin)) as? [String: Any])
        object["vad"] = vad
        return try JSONDecoder().decode(LiveSessionBegin.self,from: JSONSerialization.data(withJSONObject: object))
    }
}

@Suite struct LiveVADAdmissionTests {
    @Test func configuredVADSurvivesTheWireRatherThanSilentlyBecomingASROnly() throws {
        let f = VADWireFixture(), begin = try f.decode(f.vad)
        #expect(begin.isValid)
        let reencoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(begin)) as? [String: Any])
        #expect(reencoded["vad"] != nil)
        #expect(try JSONDecoder().decode(LiveSessionBegin.self,from: JSONEncoder().encode(begin)) == begin)
        #expect(begin.vad?.modelPath == "/fixture/silero.mlmodelc")
        #expect(begin.vad?.identity.modelFingerprint == String(repeating: "a",count: 64))
    }

    @Test func malformedVADRejectsBeforeAnySDKPreconditionOrModelLoad() throws {
        let f = VADWireFixture()
        for (key,value): (String,Any) in [("modelFingerprint","bad"),("runtimeRevision",""),
            ("positiveThreshold",1.1),("negativeThreshold",0.9),("minSilenceSamples",0),
            ("minSilenceSamples",240001),("speechPaddingSamples",-1),("speechPaddingSamples",4097)] {
            var vad = f.vad, identity = try #require(vad["identity"] as? [String: Any])
            identity[key] = value; vad["identity"] = identity
            #expect(!(try f.decode(vad)).isValid)
        }
        for path in ["relative.mlmodelc","/fixture/model.mlmodel","/fixture/../silero.mlmodelc","/fixture/./silero.mlmodelc"] {
            var vad = f.vad; vad["modelPath"] = path
            #expect(!(try f.decode(vad)).isValid)
        }
    }

    @Test func omittedAndNullVADKeepLegacyASROnlyCompatibility() throws {
        let f = VADWireFixture()
        #expect(try f.decode(nil).isValid)
        #expect(try f.decode(NSNull()).isValid)
    }
}

private struct VADResourceFixture {
    let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
    static var vadIdentity: LiveVADIdentity { .init(modelRevision: "silero-r1",modelFingerprint: String(repeating: "a",count: 64),
        runtimeRevision: "21493f8dac5a97e65742e6ff26f42f164c2fda0f") }
    func request(vad: LiveVADIdentity? = Self.vadIdentity, path: String = "/fixture/silero.mlmodelc", labels: Bool = false) -> LiveResourceRequest {
        .init(profileID: "vad-fixture",hardware: "fixture-mac",modelRevision: "asr-r1",chunkMs: 1120,sourceCount: 2,
            attributionRequested: labels,vad: vad.map { .init(identity: $0,modelPath: path) })
    }
    func profile(vad: LiveVADIdentity? = Self.vadIdentity, asr: UInt64 = 400, vadBytes: UInt64? = 120,
                 attribution: UInt64? = 200, headroom: UInt64 = 100, chat: UInt64 = 300) -> LiveResourceProfile {
        .init(id: "vad-fixture",hardware: "fixture-mac",modelRevision: "asr-r1",chunkMs: 1120,sourceCount: 2,
            qualificationID: "fixture-only",asrBytes: asr,attributionBytes: attribution,headroomBytes: headroom,
            concurrentChatModels: ["configured-model":chat],backgroundWorkQualified: false,vad: vad,vadBytes: vadBytes)
    }
    func measurement(_ available: UInt64 = 1000, pressure: LiveResourceMeasurement.Pressure = .normal) -> LiveResourceMeasurement {
        .init(availableBytes: available,pressure: pressure)
    }
}

@Suite struct LiveVADResourceAdmissionTests {
    @Test func ASROnlyAndVADProfilesCannotSubstituteForOneAnother() async {
        let f = VADResourceFixture()
        let asr = LiveModelResourcePolicy(profiles: [f.profile(vad: nil,vadBytes: nil)])
        await #expect(throws: LiveResourceRejection.unsupported) { try await asr.admit(identity: f.identity,request: f.request(),measurement: f.measurement()) }
        let vad = LiveModelResourcePolicy(profiles: [f.profile()])
        await #expect(throws: LiveResourceRejection.unsupported) { try await vad.admit(identity: f.identity,request: f.request(vad: nil),measurement: f.measurement()) }
        #expect(await asr.reservedBytes == 0)
        #expect(await vad.reservedBytes == 0)
    }

    @Test func everyFrozenIdentityFieldMustMatchTheMeasurement() async throws {
        let f = VADResourceFixture(), frozen = VADResourceFixture.vadIdentity
        let data = try JSONEncoder().encode(frozen)
        for (key,value): (String,Any) in [("modelRevision","other-r1"),("modelFingerprint",String(repeating: "b",count: 64)),
            ("runtimeRevision","other-runtime"),("computeUnits","cpuOnly"),("positiveThreshold",0.9),
            ("negativeThreshold",0.65),("minSilenceSamples",12000),("speechPaddingSamples",0)] {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]); object[key] = value
            let changed = try JSONDecoder().decode(LiveVADIdentity.self,from: JSONSerialization.data(withJSONObject: object))
            #expect(changed.isValid)
            let policy = LiveModelResourcePolicy(profiles: [f.profile()])
            await #expect(throws: LiveResourceRejection.unsupported) { try await policy.admit(identity: f.identity,request: f.request(vad: changed),measurement: f.measurement()) }
            #expect(await policy.reservedBytes == 0)
        }
    }

    @Test func mandatoryVADCostPrecedesOptionalAttribution() async throws {
        let f = VADResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile()])
        await #expect(throws: LiveResourceRejection.insufficientMemory) { try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement(619)) }
        let lease = try await policy.admit(identity: f.identity,request: f.request(labels: true),measurement: f.measurement(700))
        #expect(lease.reservedBytes == 520 && !lease.attributionEnabled)
        #expect(await policy.reservedBytes == 520)
        await policy.release(lease)
        let full = try await policy.admit(identity: f.identity,request: f.request(labels: true),measurement: f.measurement(820))
        #expect(full.reservedBytes == 720 && full.attributionEnabled)
        await policy.confirmAttributionRetired(full)
        #expect(await policy.reservedBytes == 520) // VAD allocation stays until helper exit.
        await policy.release(full)
        #expect(await policy.reservedBytes == 0)
    }

    @Test func ASRReadinessKeepsPendingVADChargedForLocalJobs() async throws {
        let f = VADResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile()])
        let lease = try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement())
        await policy.confirmResident(lease)
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(400)) == .deferred)
        #expect(await policy.reserveJob(owner: UUID(),job: .localChat(model: "configured-model"),measurement: f.measurement(400)) == nil)
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(520)) == .admitted)
        #expect(await policy.decide(.configuredRemote,measurement: f.measurement(0,pressure: .critical)) == .admitted)
        let stale = LiveResourceLease(id: UUID(),identity: lease.identity,request: lease.request,attributionEnabled: lease.attributionEnabled,reservedBytes: lease.reservedBytes)
        await policy.confirmVADResident(stale)
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(400)) == .deferred)
        await policy.confirmVADResident(lease)
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(400)) == .admitted)
        #expect(await policy.reservedBytes == 520)
        #expect(await policy.validateActiveLease(lease))
        #expect(await !policy.validateActiveLease(stale))
        await policy.release(stale)
        #expect(await policy.reservedBytes == 520)
        await policy.release(lease)
        #expect(await !policy.validateActiveLease(lease))
    }

    @Test func VADAndPendingAttributionBothRemainAdditionalAllocationsAfterASRReady() async throws {
        let f = VADResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile()])
        let lease = try await policy.admit(identity: f.identity,request: f.request(labels: true),measurement: f.measurement())
        await policy.confirmResident(lease)
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(719)) == .deferred)
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(720)) == .admitted)
        await policy.confirmVADResident(lease)
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(599)) == .deferred)
        await policy.confirmAttributionRetired(lease)
        #expect(await policy.decide(.localChat(model: "configured-model"),measurement: f.measurement(400)) == .admitted)
        #expect(await policy.reservedBytes == 520)
    }

    @Test func preexistingJobCannotSpendPendingVADAllocation() async throws {
        let f = VADResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile()])
        let job = try #require(await policy.reserveJob(owner: UUID(),job: .localChat(model: "configured-model"),measurement: f.measurement()))
        await #expect(throws: LiveResourceRejection.insufficientMemory) { try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement(919)) }
        #expect(await policy.reservedBytes == 0)
        let lease = try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement(920))
        #expect(lease.reservedBytes == 520)
        await policy.release(lease)
        await policy.confirmJobResident(job)
        #expect(try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement(620)).reservedBytes == 520)
    }

    @Test func portableProfileAllowsDifferentCachesButAnActiveLeaseFreezesItsPath() async throws {
        let f = VADResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile()])
        let lease = try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement())
        await #expect(throws: LiveResourceRejection.configurationChanged) { try await policy.admit(identity: f.identity,request: f.request(path: "/other/silero.mlmodelc"),measurement: f.measurement()) }
        await policy.release(lease)
        let next = try await policy.admit(identity: f.identity,request: f.request(path: "/other/silero.mlmodelc"),measurement: f.measurement())
        #expect(next.request.vad?.modelPath == "/other/silero.mlmodelc" && next.reservedBytes == 520)
    }

    @Test func invalidCostsAndEveryCombinedOverflowRejectBeforeAllocation() async {
        let f = VADResourceFixture()
        let invalid = [f.profile(vad: nil),f.profile(vadBytes: nil),f.profile(vadBytes: 0),
            f.profile(asr: .max,vadBytes: 1,attribution: nil,headroom: 0,chat: 1),
            f.profile(vadBytes: .max-500,attribution: 200,headroom: 0,chat: 1),
            f.profile(vadBytes: .max-450,attribution: nil,headroom: 100,chat: 1),
            f.profile(vadBytes: .max-500,attribution: nil,headroom: 0,chat: 101)]
        for profile in invalid {
            let policy = LiveModelResourcePolicy(profiles: [profile])
            await #expect(throws: LiveResourceRejection.invalidProfile) { try await policy.admit(identity: f.identity,request: f.request(),measurement: f.measurement(.max)) }
            #expect(await policy.reservedBytes == 0)
        }
    }

    @Test func malformedRequestedCacheAndMalformedProfileIdentityCannotAdmit() async {
        let f = VADResourceFixture(), policy = LiveModelResourcePolicy(profiles: [f.profile()])
        await #expect(throws: LiveResourceRejection.unsupported) { try await policy.admit(identity: f.identity,request: f.request(path: "relative.mlmodelc"),measurement: f.measurement()) }
        let invalid = LiveVADIdentity(modelRevision: "silero-r1",modelFingerprint: "bad",runtimeRevision: "runtime")
        let badProfile = LiveModelResourcePolicy(profiles: [f.profile(vad: invalid)])
        await #expect(throws: LiveResourceRejection.invalidProfile) { try await badProfile.admit(identity: f.identity,request: f.request(vad: invalid),measurement: f.measurement()) }
        #expect(await policy.reservedBytes == 0)
        #expect(await badProfile.reservedBytes == 0)
    }
}
