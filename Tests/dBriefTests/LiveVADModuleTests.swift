import Foundation
import Testing
import dBriefWire
@testable import dBrief

private struct VADModuleFixture {
    let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
    let micID = UUID(), systemID = UUID()
    let vad = LiveVADIdentity(modelRevision: "silero-r1",modelFingerprint: String(repeating: "a",count: 64),
        runtimeRevision: "21493f8dac5a97e65742e6ff26f42f164c2fda0f")
    func scope(_ source: LiveSource = .microphone) -> LiveLaneScope {
        .init(identity: identity,source: source,epochID: source == .microphone ? micID : systemID)
    }
    func begin(both: Bool = true, configured: Bool = true) -> LiveSessionBegin {
        .init(identity: identity,configuration: .init(language: .auto,modelDirectory: "/fixture/asr"),
            epochs: (both ? [LiveSource.microphone,.system] : [.microphone]).map {
                .init(id: scope($0).epochID,source: $0,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
            },vad: configured ? .init(identity: vad,modelPath: "/fixture/silero.mlmodelc") : nil)
    }
    func active(_ source: LiveSource = .microphone, context: UUID = UUID()) throws -> LiveVADModuleLedger {
        var ledger = try LiveVADModuleLedger(input: begin())
        try ledger.observe(scope: scope(source),event: .preparing(identity: vad),admittedEnd: 0)
        try ledger.observe(scope: scope(source),event: .ready(identity: vad,contextID: context,originSample: 0),admittedEnd: 0)
        return ledger
    }
}

@Suite struct LiveVADModuleTests {
    @Test func portableEventsRoundTripWithoutCachePathAndKeepLegacyFramesUnchanged() throws {
        let f = VADModuleFixture(), context = UUID()
        let events: [LiveVADModuleEvent] = [.preparing(identity: f.vad),.ready(identity: f.vad,contextID: context,originSample: 0),
            .processed(identity: f.vad,contextID: context,sampleEnd: 4096),
            .degraded(identity: f.vad,contextID: context,sampleEnd: 4096),.degraded(identity: f.vad,contextID: nil,sampleEnd: 0),
            .retired(identity: f.vad,contextID: context,sampleEnd: 4096),.retired(identity: f.vad,contextID: nil,sampleEnd: 0)]
        for event in events {
            let frame = LiveSessionEvent.lane(.init(scope: f.scope(),sequence: 3,payload: .vad(event)))
            let data = try JSONEncoder().encode(frame)
            #expect(try JSONDecoder().decode(LiveSessionEvent.self,from: data) == frame)
            #expect(!String(decoding: data,as: UTF8.self).contains("/fixture"))
        }
        let legacy = Data("{\"ready\":{\"generation\":\"11111111-1111-1111-1111-111111111111\",\"originSample\":0}}".utf8)
        let payload = try JSONDecoder().decode(LiveLaneEvent.Payload.self,from: legacy)
        #expect(try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? NSDictionary == JSONSerialization.jsonObject(with: legacy) as? NSDictionary)
    }

    @Test func configuredValidBeginIsRequiredAndOwnerSizeIsBounded() throws {
        let f = VADModuleFixture()
        #expect(throws: LiveProtocolError.invalidConfiguration) { try LiveVADModuleLedger(input: f.begin(configured: false)) }
        let invalid = LiveSessionBegin(identity: f.identity,configuration: f.begin().configuration,epochs: [],vad: f.begin().vad)
        #expect(throws: LiveProtocolError.invalidConfiguration) { try LiveVADModuleLedger(input: invalid) }
        let single = try LiveVADModuleLedger(input: f.begin(both: false))
        #expect(single.status(for: .system) == nil && single.status(for: .finalMix) == nil)
        #expect(single.status(for: .microphone)?.phase == .unknown && !single.allModelsReady)
    }

    @Test func statusRequiresItsWholeFrozenIdentityOnTheWire() throws {
        let f = VADModuleFixture()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(LiveVADModuleEvent.preparing(identity: f.vad))) as? [String: Any])
        var payload = try #require(object["preparing"] as? [String: Any])
        payload.removeValue(forKey: "identity"); object["preparing"] = payload
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LiveVADModuleEvent.self,from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func orderedWindowsAdvanceOnlyTheirOwnSourceWithoutCreditOrCoverage() throws {
        let f = VADModuleFixture(), context = UUID()
        var ledger = try f.active(context: context)
        #expect(ledger.status(for: .microphone)?.modelReadySeen == true)
        #expect(ledger.status(for: .microphone)?.contextID == context)
        #expect(!ledger.allModelsReady)
        for end: Int64 in [4096,8192,12288] {
            try ledger.observe(scope: f.scope(),event: .processed(identity: f.vad,contextID: context,sampleEnd: end),admittedEnd: end)
            #expect(ledger.status(for: .microphone)?.processedEnd == end)
            #expect(ledger.status(for: .system)?.processedEnd == 0)
        }
        try ledger.observe(scope: f.scope(.system),event: .preparing(identity: f.vad),admittedEnd: 0)
        try ledger.observe(scope: f.scope(.system),event: .ready(identity: f.vad,contextID: UUID(),originSample: 0),admittedEnd: 0)
        #expect(ledger.allModelsReady)
    }

    @Test(arguments: ["unknown","preparing","active"])
    func degradationPreservesActualReadyFactAndCannotExpandFrontier(phase: String) throws {
        let f = VADModuleFixture(), context = UUID()
        let initial = phase != "active"
        var ledger = initial ? try LiveVADModuleLedger(input: f.begin()) : try f.active(context: context)
        if phase == "preparing" { try ledger.observe(scope: f.scope(),event: .preparing(identity: f.vad),admittedEnd: 0) }
        if !initial { try ledger.observe(scope: f.scope(),event: .processed(identity: f.vad,contextID: context,sampleEnd: 4096),admittedEnd: 4096) }
        let id: UUID? = initial ? nil : context, end: Int64 = initial ? 0 : 4096
        try ledger.observe(scope: f.scope(),event: .degraded(identity: f.vad,contextID: id,sampleEnd: end),admittedEnd: 4096)
        #expect(ledger.status(for: .microphone)?.phase == .degraded)
        #expect(ledger.status(for: .microphone)?.nativeFailureSeen == true)
        #expect(ledger.status(for: .microphone)?.modelReadySeen == !initial)
        let before = ledger
        for event: LiveVADModuleEvent in [.degraded(identity: f.vad,contextID: id,sampleEnd: end),
            .retired(identity: f.vad,contextID: id,sampleEnd: end+4096),.ready(identity: f.vad,contextID: context,originSample: 0),
            .processed(identity: f.vad,contextID: context,sampleEnd: end+4096)] {
            #expect(throws: LiveProtocolError.outOfOrder) { try ledger.observe(scope: f.scope(),event: event,admittedEnd: 8192) }
            #expect(ledger == before)
        }
        try ledger.observe(scope: f.scope(),event: .retired(identity: f.vad,contextID: id,sampleEnd: end),admittedEnd: 4096)
        #expect(ledger.status(for: .microphone)?.phase == .retired)
    }

    @Test(arguments: ["unknown","preparing","active","degraded","retired"])
    func illegalTransitionsAreAtomic(phase: String) throws {
        let f = VADModuleFixture(), context = UUID()
        var ledger = try LiveVADModuleLedger(input: f.begin())
        if phase != "unknown" { try ledger.observe(scope: f.scope(),event: .preparing(identity: f.vad),admittedEnd: 0) }
        if ["active","degraded","retired"].contains(phase) { try ledger.observe(scope: f.scope(),event: .ready(identity: f.vad,contextID: context,originSample: 0),admittedEnd: 0) }
        if phase == "degraded" { try ledger.observe(scope: f.scope(),event: .degraded(identity: f.vad,contextID: context,sampleEnd: 0),admittedEnd: 0) }
        if phase == "retired" { try ledger.observe(scope: f.scope(),event: .retired(identity: f.vad,contextID: context,sampleEnd: 0),admittedEnd: 0) }
        var invalid: [LiveVADModuleEvent] = [.ready(identity: f.vad,contextID: context,originSample: 1)]
        if phase != "unknown" { invalid.append(.preparing(identity: f.vad)) }
        if phase != "preparing" { invalid.append(.ready(identity: f.vad,contextID: context,originSample: 0)) }
        if phase != "active" { invalid.append(.processed(identity: f.vad,contextID: context,sampleEnd: 4096)) }
        if ["active","degraded","retired"].contains(phase) { invalid.append(.retired(identity: f.vad,contextID: nil,sampleEnd: 0)) }
        if phase == "retired" { invalid += [.degraded(identity: f.vad,contextID: context,sampleEnd: 0),.retired(identity: f.vad,contextID: context,sampleEnd: 0)] }
        let before = ledger
        for event in invalid {
            #expect(throws: LiveProtocolError.outOfOrder) { try ledger.observe(scope: f.scope(),event: event,admittedEnd: 4096) }
            #expect(ledger == before)
        }
    }

    @Test func malformedWindowsAndForeignIdentitiesRollbackBothSourcesThenAllowRetry() throws {
        let f = VADModuleFixture(), context = UUID()
        var ledger = try f.active(context: context)
        let before = ledger
        for end: Int64 in [-1,0,4095,4097,8192,.max,.min] {
            #expect(throws: LiveProtocolError.outOfOrder) { try ledger.observe(scope: f.scope(),event: .processed(identity: f.vad,contextID: context,sampleEnd: end),admittedEnd: .max) }
            #expect(ledger == before)
        }
        for admitted: Int64 in [-1,0,4095] {
            #expect(throws: LiveProtocolError.outOfOrder) { try ledger.observe(scope: f.scope(),event: .processed(identity: f.vad,contextID: context,sampleEnd: 4096),admittedEnd: admitted) }
            #expect(ledger == before)
        }
        #expect(throws: LiveProtocolError.outOfOrder) { try ledger.observe(scope: f.scope(),event: .processed(identity: f.vad,contextID: UUID(),sampleEnd: 4096),admittedEnd: 4096) }
        let data = try JSONEncoder().encode(f.vad)
        for (key,value): (String,Any) in [("modelRevision","other"),("modelFingerprint",String(repeating: "b",count: 64)),
            ("runtimeRevision","other"),("implementationRevision","other"),("computeUnits","cpuOnly"),
            ("positiveThreshold",0.9),("negativeThreshold",0.6),("minSilenceSamples",4096),("speechPaddingSamples",0),
            ("modelFingerprint","bad")] {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]); object[key] = value
            let changed = try JSONDecoder().decode(LiveVADIdentity.self,from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: LiveProtocolError.invalidConfiguration) { try ledger.observe(scope: f.scope(),event: .processed(identity: changed,contextID: context,sampleEnd: 4096),admittedEnd: 4096) }
            #expect(ledger == before)
        }
        for scope in [LiveLaneScope(identity: f.identity,source: .microphone,epochID: UUID()),
            .init(identity: f.identity,source: .finalMix,epochID: f.micID),.init(identity: f.identity,source: .system,epochID: f.micID),
            .init(identity: .init(recordingID: UUID(),captureSessionID: f.identity.captureSessionID),source: .microphone,epochID: f.micID)] {
            #expect(throws: LiveProtocolError.staleScope) { try ledger.observe(scope: scope,event: .processed(identity: f.vad,contextID: context,sampleEnd: 4096),admittedEnd: 4096) }
            #expect(ledger == before)
        }
        try ledger.observe(scope: f.scope(),event: .processed(identity: f.vad,contextID: context,sampleEnd: 4096),admittedEnd: 4096)
        #expect(ledger.status(for: .microphone)?.processedEnd == 4096)
    }

    @Test(arguments: ["active","degraded","retired"])
    func peerContextReservationSurvivesLogicalClosure(phase: String) throws {
        let f = VADModuleFixture(), context = UUID()
        var ledger = try f.active(context: context)
        if phase == "degraded" { try ledger.observe(scope: f.scope(),event: .degraded(identity: f.vad,contextID: context,sampleEnd: 0),admittedEnd: 0) }
        if phase == "retired" { try ledger.observe(scope: f.scope(),event: .retired(identity: f.vad,contextID: context,sampleEnd: 0),admittedEnd: 0) }
        try ledger.observe(scope: f.scope(.system),event: .preparing(identity: f.vad),admittedEnd: 0)
        let before = ledger
        #expect(throws: LiveProtocolError.outOfOrder) { try ledger.observe(scope: f.scope(.system),event: .ready(identity: f.vad,contextID: context,originSample: 0),admittedEnd: 0) }
        #expect(ledger == before)
        try ledger.observe(scope: f.scope(.system),event: .ready(identity: f.vad,contextID: UUID(),originSample: 0),admittedEnd: 0)
        #expect(ledger.allModelsReady)
    }

    @Test(arguments: [false,true])
    func replacementResetsEpochCoverageButRetainsFailureAndReadinessFacts(failed: Bool) throws {
        let f = VADModuleFixture(), context = UUID()
        var ledger = try f.active(context: context)
        try ledger.observe(scope: f.scope(),event: .processed(identity: f.vad,contextID: context,sampleEnd: 4096),admittedEnd: 4096)
        if failed { try ledger.observe(scope: f.scope(),event: .degraded(identity: f.vad,contextID: context,sampleEnd: 4096),admittedEnd: 4096) }
        try ledger.observe(scope: f.scope(),event: .retired(identity: f.vad,contextID: context,sampleEnd: 4096),admittedEnd: 4096)
        let next = LiveLaneScope(identity: f.identity,source: .microphone,epochID: UUID())
        try ledger.installAcceptedReplacement(oldScope: f.scope(),newScope: next)
        let status = try #require(ledger.status(for: .microphone))
        #expect(status.scope == next && status.phase == .unknown && status.contextID == nil && status.processedEnd == 0)
        #expect(status.modelReadySeen && status.nativeFailureSeen == failed)
        let before = ledger
        #expect(throws: LiveProtocolError.staleScope) { try ledger.observe(scope: f.scope(),event: .processed(identity: f.vad,contextID: context,sampleEnd: 8192),admittedEnd: 8192) }
        #expect(ledger == before)
        if failed {
            #expect(throws: LiveProtocolError.outOfOrder) { try ledger.observe(scope: next,event: .preparing(identity: f.vad),admittedEnd: 0) }
            #expect(throws: LiveProtocolError.outOfOrder) { try ledger.observe(scope: next,event: .ready(identity: f.vad,contextID: UUID(),originSample: 0),admittedEnd: 0) }
            #expect(ledger == before)
            try ledger.observe(scope: next,event: .degraded(identity: f.vad,contextID: nil,sampleEnd: 0),admittedEnd: 0)
        } else {
            try ledger.observe(scope: next,event: .preparing(identity: f.vad),admittedEnd: 0)
            try ledger.observe(scope: next,event: .ready(identity: f.vad,contextID: UUID(),originSample: 0),admittedEnd: 0)
            #expect(ledger.status(for: .microphone)?.processedEnd == 0)
        }
    }

    @Test func replacementRequiresExactRetiredScopeAndDoesNotStealPeerEpoch() throws {
        let f = VADModuleFixture(), context = UUID()
        var ledger = try f.active(context: context)
        let fresh = LiveLaneScope(identity: f.identity,source: .microphone,epochID: UUID())
        let before = ledger
        #expect(throws: LiveProtocolError.outOfOrder) { try ledger.installAcceptedReplacement(oldScope: f.scope(),newScope: fresh) }
        #expect(ledger == before)
        try ledger.observe(scope: f.scope(),event: .retired(identity: f.vad,contextID: context,sampleEnd: 0),admittedEnd: 0)
        let retired = ledger
        for next in [f.scope(),LiveLaneScope(identity: f.identity,source: .microphone,epochID: f.systemID),f.scope(.system)] {
            #expect(throws: LiveProtocolError.outOfOrder) { try ledger.installAcceptedReplacement(oldScope: f.scope(),newScope: next) }
            #expect(ledger == retired)
        }
        #expect(throws: LiveProtocolError.staleScope) { try ledger.installAcceptedReplacement(oldScope: fresh,newScope: f.scope()) }
        #expect(ledger == retired)
    }

    @Test(arguments: [false,true])
    func initialRetirementNeedsNoInventedReadiness(preparing: Bool) throws {
        let f = VADModuleFixture()
        var ledger = try LiveVADModuleLedger(input: f.begin())
        if preparing { try ledger.observe(scope: f.scope(),event: .preparing(identity: f.vad),admittedEnd: 0) }
        try ledger.observe(scope: f.scope(),event: .retired(identity: f.vad,contextID: nil,sampleEnd: 0),admittedEnd: 0)
        #expect(ledger.status(for: .microphone)?.phase == .retired)
        #expect(ledger.status(for: .microphone)?.modelReadySeen == false)
        #expect(ledger.status(for: .microphone)?.nativeFailureSeen == false)
    }
}
