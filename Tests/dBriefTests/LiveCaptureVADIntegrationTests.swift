import Foundation
import Testing
import dBriefWire
@testable import dBrief

private actor AppModuleTransport {
    let stream: AsyncThrowingStream<LiveSessionEvent, Error>
    let output: AsyncThrowingStream<LiveSessionEvent, Error>.Continuation
    var starts = 0
    var requests: [LiveSessionRequest] = []
    var shutdowns = 0
    var teardownWaiter: CheckedContinuation<Void, Never>?
    var holdTeardown = false
    var replacementEvents: [LiveSessionEvent] = []
    var replacementReply: LiveSessionReply = .accepted
    var replacementFailure = false
    var replacementReturns = 0
    var replacementStarts = 0
    var heldReplacementSources: Set<LiveSource> = []
    var replacementWaiters: [LiveSource: CheckedContinuation<Void, Never>] = [:]
    var heldAfterEvents: Set<LiveSource> = []
    var afterEventsWaiters: [LiveSource: CheckedContinuation<Void, Never>] = [:]

    init() { (stream,output) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(128)) }
    func begin(_ input: LiveSessionBegin) -> AsyncThrowingStream<LiveSessionEvent, Error> { starts += 1; return stream }
    func command(_ request: LiveSessionRequest) async throws -> LiveSessionReply {
        requests.append(request)
        if case .replaceEpoch(_,_,let epoch) = request {
            replacementStarts += 1
            if heldReplacementSources.contains(epoch.source) { await withCheckedContinuation { replacementWaiters[epoch.source] = $0 } }
            if replacementFailure { throw LiveProtocolError.unavailable }
            for event in replacementEvents { output.yield(event) }
            if heldAfterEvents.contains(epoch.source) { await withCheckedContinuation { afterEventsWaiters[epoch.source] = $0 } }
            replacementReturns += 1
            return replacementReply
        }
        return .accepted
    }
    func setReplacementEvents(_ events: [LiveSessionEvent]) { replacementEvents = events }
    func setReplacementReply(_ reply: LiveSessionReply, failure: Bool = false) { replacementReply = reply; replacementFailure = failure }
    func blockReplacement(_ source: LiveSource) { heldReplacementSources.insert(source) }
    func blockReplyAfterEvents(_ source: LiveSource) { heldAfterEvents.insert(source) }
    func releaseReplacement() {
        heldReplacementSources.removeAll()
        let held = replacementWaiters; replacementWaiters.removeAll()
        for waiter in held.values { waiter.resume() }
        heldAfterEvents.removeAll()
        let replies = afterEventsWaiters; afterEventsWaiters.removeAll()
        for waiter in replies.values { waiter.resume() }
    }
    func shutdown() async {
        shutdowns += 1
        if holdTeardown { await withCheckedContinuation { teardownWaiter = $0 } }
    }
    func blockTeardown() { holdTeardown = true }
    func release() { releaseReplacement(); holdTeardown = false; teardownWaiter?.resume(); teardownWaiter = nil }
    func emit(_ event: LiveSessionEvent) { output.yield(event) }
    func transport() -> LiveASRTransport {
        .init(begin: { await self.begin($0) },command: { try await self.command($0) },deadline: { _ in },shutdown: { await self.shutdown() })
    }
}

private struct AppModuleFixture {
    let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
    let mic = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
    let system = LiveEpoch(id: UUID(),source: .system,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
    let vad = LiveVADConfiguration(identity: .init(modelRevision: "silero-r1",modelFingerprint: String(repeating: "a",count: 64),
        runtimeRevision: "21493f8dac5a97e65742e6ff26f42f164c2fda0f"),modelPath: "/fixture/silero.mlmodelc")
    func scope(_ epoch: LiveEpoch) -> LiveLaneScope { .init(identity: identity,source: epoch.source,epochID: epoch.id) }
    func event(_ epoch: LiveEpoch, _ sequence: UInt64, _ payload: LiveLaneEvent.Payload) -> LiveSessionEvent {
        .lane(.init(scope: scope(epoch),sequence: sequence,payload: payload))
    }
    func input(both: Bool = false, configured: Bool = true) -> LiveSessionBegin {
        .init(identity: identity,configuration: .init(language: .auto,chunkMs: 1120,modelDirectory: "/fixture"),
            epochs: both ? [mic,system] : [mic],vad: configured ? vad : nil)
    }
    func coordinator(_ transport: AppModuleTransport, both: Bool = false, configured: Bool = true,
                     ingress: LiveCaptureIngress? = nil, storeAccess: LiveCaptureStoreAccess? = nil,
                     epochHistoryLimit: Int = 4096) async throws
        -> (LiveCaptureSessionCoordinator,LiveTranscriptStore,LiveModelResourcePolicy) {
        let begin = input(both: both,configured: configured)
        let profile = LiveResourceProfile(id: "fixture",hardware: "fixture",modelRevision: "fixture",chunkMs: 1120,sourceCount: begin.epochs.count,
            qualificationID: "fixture-only",asrBytes: 400,attributionBytes: nil,headroomBytes: 100,
            concurrentChatModels: ["fixture-chat":300],backgroundWorkQualified: false,vad: begin.vad?.identity,vadBytes: configured ? 120 : nil)
        let resources = LiveModelResourcePolicy(profiles: [profile])
        let lease = try await resources.admit(identity: identity,request: .init(profileID: "fixture",hardware: "fixture",modelRevision: "fixture",
            chunkMs: 1120,sourceCount: begin.epochs.count,attributionRequested: false,vad: begin.vad),measurement: .init(availableBytes: 1000,pressure: .normal))
        let store = LiveTranscriptStore(identity: identity)
        let coordinator = LiveCaptureSessionCoordinator(input: begin,store: store,transport: await transport.transport(),resources: resources,lease: lease,
            ingress: ingress,storeAccess: storeAccess,epochHistoryLimit: epochHistoryLimit)
        return (coordinator,store,resources)
    }
    func activate(_ epoch: LiveEpoch, transport: AppModuleTransport, context: UUID = UUID()) async {
        await transport.emit(event(epoch,0,.vad(.preparing(identity: vad.identity))))
        await transport.emit(event(epoch,1,.vad(.ready(identity: vad.identity,contextID: context,originSample: 0))))
        await transport.emit(event(epoch,2,.ready(generation: UUID(),originSample: 0)))
    }
    func progress(_ end: Int64, credit: Int64 = 49920) -> LiveHelperProgress {
        .init(capturedSampleEnd: end,admittedSampleEnd: end,consumedSampleEnd: end,queuedSamples: 0,inFlightSamples: 0,
              heldSamples: 0,creditSamples: credit,asrConsumedSampleEnd: end)
    }
}

private actor AppModulePreflightGate {
    let blockedSources: Set<LiveSource>
    var arrivals: [UUID] = []
    var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    init(blockedSources: Set<LiveSource> = [.microphone]) { self.blockedSources = blockedSources }
    func check(owner: LiveSessionIdentity, epoch: LiveEpoch, store: LiveTranscriptStore) async -> LiveStoreAdmission {
        arrivals.append(epoch.id)
        if blockedSources.contains(epoch.source) { await withCheckedContinuation { waiters[epoch.id] = $0 } }
        return await store.checkEpoch(owner: owner,epoch: epoch)
    }
    func release() { let held = waiters; waiters.removeAll(); for waiter in held.values { waiter.resume() } }
}

private func appModuleEventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<500 { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(2)) }
    return false
}

@Suite struct LiveCaptureVADIntegrationTests {
    @Test(arguments: [false,true])
    func CallerCancellationKeepsTheProposedOwnerUntilActualPreflightOrNativeReturn(afterDispatch: Bool) async throws {
        let f = AppModuleFixture(), t = AppModuleTransport(), gate = AppModulePreflightGate()
        let store = LiveTranscriptStore(identity: f.identity)
        let access = LiveCaptureStoreAccess(admit: { await store.admit($0) },checkEpoch: { owner,epoch in
            if afterDispatch { return await store.checkEpoch(owner: owner,epoch: epoch) }
            return await gate.check(owner: owner,epoch: epoch,store: store)
        })
        let c = LiveCaptureSessionCoordinator(input: f.input(both: true,configured: false),store: store,transport: await t.transport(),
            storeAccess: access,epochHistoryLimit: 4)
        defer { Task { await gate.release(); await t.release(); await c.retire() } }
        try await c.start()
        for epoch in [f.mic,f.system] { await t.emit(f.event(epoch,0,.ready(generation: UUID(),originSample: 0))) }
        try #require(await appModuleEventually { await c.readySources.count == 2 })
        for epoch in [f.mic,f.system] { await c.recordDiscontinuity(scope: f.scope(epoch),reason: .deviceInterruption) }
        try #require(await appModuleEventually {
            let mic = await c.streamState(source: .microphone), system = await c.streamState(source: .system)
            return mic?.replacementReady == true && system?.replacementReady == true
        })
        if afterDispatch { await t.blockReplacement(.microphone) }
        let fresh = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        let replacing = Task { try await c.replaceEpoch(scope: f.scope(f.mic),epoch: fresh) }
        try #require(await appModuleEventually {
            if afterDispatch { return await t.replacementStarts == 1 }
            return await gate.arrivals == [fresh.id]
        })
        replacing.cancel()
        let duplicate = LiveEpoch(id: fresh.id,source: .system,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        #expect(try await c.replaceEpoch(scope: f.scope(f.system),epoch: duplicate) == false)
        if afterDispatch { await t.releaseReplacement() }
        else { await gate.release() }
        #expect(try await replacing.value == false)
        #expect(try await c.replaceEpoch(scope: f.scope(f.system),epoch: duplicate) == !afterDispatch)
        #expect(await t.replacementStarts == 1)
        #expect(!(await store.projection().isClosed))
    }

    @Test(arguments: ["active-lie","retired-lie","processed-valid","degraded-valid"])
    func CommonProgressCannotReleaseHealthyVADInputPastItsProcessedFrontier(mode: String) async throws {
        let f = AppModuleFixture(), t = AppModuleTransport(), context = UUID()
        let ingress = LiveCaptureIngress(input: f.input())
        let (c,store,_) = try await f.coordinator(t,ingress: ingress)
        await t.blockTeardown()
        defer { Task { await t.release(); await c.retire() } }
        try await c.start(); await f.activate(f.mic,transport: t,context: context)
        try #require(await appModuleEventually { await c.readySources == [.microphone] })
        let counts = mode == "processed-valid" ? [3200,896] : [3200]
        let rawEpoch = UUID()
        var end: Int64 = 0, sequence: UInt64 = 3
        for (index,count) in counts.enumerated() {
            let metadata = LiveAudioMetadata(sourceEpoch: rawEpoch,role: .mic,timestamp: .unavailable,
                emittedFrames: .init(startFrame: end,frameCount: Int64(count),sampleRate: 16000),writeOutcome: .failed,converter: nil)
            let raw = try #require(ingress.reserveRaw(source: .microphone,metadata: metadata,frames: count,rate: 16000,bytes: count*4))
            let normalized = try #require(ingress.normalize(raw,scope: f.scope(f.mic),emittedSamples: count))
            #expect(await c.offer(scope: f.scope(f.mic),samples: Array(repeating: 0.25,count: count),reservation: normalized) == .scheduled)
            end += Int64(count)
            try #require(await appModuleEventually { await t.requests.count == index+1 })
            await t.emit(f.event(f.mic,sequence,.admitted(packetSequence: UInt64(index),sampleEnd: end))); sequence += 1
        }
        let admitted = end
        try #require(await appModuleEventually { await store.projection().lanes.first?.progress.admittedSampleEnd == admitted })
        if mode == "processed-valid" {
            await t.emit(f.event(f.mic,sequence,.vad(.processed(identity: f.vad.identity,contextID: context,sampleEnd: 4096)))); sequence += 1
        } else if mode == "degraded-valid" {
            await t.emit(f.event(f.mic,sequence,.vad(.degraded(identity: f.vad.identity,contextID: context,sampleEnd: 0)))); sequence += 1
            // A later held progress marker proves degradation was observed;
            // that metadata alone still cannot return a single native sample.
            await t.emit(f.event(f.mic,sequence,.progress(.init(capturedSampleEnd: 3200,admittedSampleEnd: 3200,consumedSampleEnd: 0,
                queuedSamples: 0,inFlightSamples: 0,heldSamples: 3200,creditSamples: 46720,asrConsumedSampleEnd: 3200)))); sequence += 1
            await t.emit(f.event(f.mic,sequence,.partial(.init(epochID: f.mic.id,source: .microphone,revision: 0,
                samples: .init(start: 0,end: 3200),text: "Failure observed, input still held")))); sequence += 1
            try #require(await appModuleEventually { await store.projection().partials.first?.text == "Failure observed, input still held" })
            #expect(ingress.statistics(.microphone).nativeSamples == 3200)
        } else if mode == "retired-lie" {
            await t.emit(f.event(f.mic,sequence,.vad(.retired(identity: f.vad.identity,contextID: context,sampleEnd: 0)))); sequence += 1
        }
        await t.emit(f.event(f.mic,sequence,.progress(f.progress(end))))
        if mode.hasSuffix("lie") {
            #expect(await appModuleEventually { await store.projection().isClosed })
            #expect(await store.projection().lanes.first?.progress.consumedSampleEnd == 0)
            #expect(ingress.statistics(.microphone).nativeSamples == 3200)
        } else {
            #expect(await appModuleEventually { ingress.statistics(.microphone).nativeSamples == 0 })
            #expect(!(await store.projection().isClosed))
            #expect(await store.projection().segments.isEmpty)
        }
    }

    @Test func UnresolvedReplacementCapacitySurvivesAbandonmentUntilActualReply() async throws {
        let f = AppModuleFixture(), t = AppModuleTransport()
        let (c,_,_) = try await f.coordinator(t,both: true,configured: false,epochHistoryLimit: 4)
        defer { Task { await t.release(); await c.retire() } }
        try await c.start()
        for epoch in [f.mic,f.system] { await t.emit(f.event(epoch,0,.ready(generation: UUID(),originSample: 0))) }
        try #require(await appModuleEventually { await c.readySources.count == 2 })
        for epoch in [f.mic,f.system] { await c.recordDiscontinuity(scope: f.scope(epoch),reason: .deviceInterruption) }
        try #require(await appModuleEventually {
            let mic = await c.streamState(source: .microphone), system = await c.streamState(source: .system)
            return mic?.replacementReady == true && system?.replacementReady == true
        })
        await t.blockReplacement(.microphone)
        let fresh = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        let replacing = Task { try await c.replaceEpoch(scope: f.scope(f.mic),epoch: fresh) }
        try #require(await appModuleEventually { await t.replacementStarts == 1 })
        await c.abandonSource(scope: f.scope(f.mic))
        let duplicate = LiveEpoch(id: fresh.id,source: .system,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        #expect(try await c.replaceEpoch(scope: f.scope(f.system),epoch: duplicate) == false)
        #expect(await t.replacementStarts == 1)
        #expect(await t.replacementReturns == 0)
        await t.releaseReplacement()
        #expect(try await replacing.value == false)
        #expect(try await c.replaceEpoch(scope: f.scope(f.system),epoch: duplicate) == false)
        #expect(await t.replacementStarts == 1)
        #expect(await t.replacementReturns == 1)
    }

    @Test func UncertainTransportFailureRetainsTheFinalCapacitySlotUntilActualExit() async throws {
        let f = AppModuleFixture(), t = AppModuleTransport()
        let (c,_,resources) = try await f.coordinator(t,both: true,configured: false,epochHistoryLimit: 3)
        await t.blockTeardown()
        defer { Task { await t.release(); await c.retire() } }
        try await c.start()
        for epoch in [f.mic,f.system] { await t.emit(f.event(epoch,0,.ready(generation: UUID(),originSample: 0))) }
        try #require(await appModuleEventually { await c.readySources.count == 2 })
        for epoch in [f.mic,f.system] { await c.recordDiscontinuity(scope: f.scope(epoch),reason: .deviceInterruption) }
        try #require(await appModuleEventually {
            let mic = await c.streamState(source: .microphone), system = await c.streamState(source: .system)
            return mic?.replacementReady == true && system?.replacementReady == true
        })
        await t.setReplacementReply(.accepted,failure: true)
        let fresh = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        await #expect(throws: LiveProtocolError.unavailable) { try await c.replaceEpoch(scope: f.scope(f.mic),epoch: fresh) }
        await t.setReplacementReply(.accepted)
        let peer = LiveEpoch(id: UUID(),source: .system,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        #expect(try await c.replaceEpoch(scope: f.scope(f.system),epoch: peer) == false)
        #expect(await t.replacementStarts == 1)
        await c.retire()
        try #require(await appModuleEventually { await t.shutdowns == 1 })
        #expect(await resources.reservedBytes == 400)
        await t.release()
        #expect(await appModuleEventually { await resources.reservedBytes == 0 })
    }

    @Test func KnownRejectionReleasesTheExactSlotAndAllowsTheSameProposalToRetry() async throws {
        let f = AppModuleFixture(), t = AppModuleTransport()
        let (c,store,_) = try await f.coordinator(t,configured: false,epochHistoryLimit: 2)
        defer { Task { await c.retire() } }
        try await c.start()
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        try #require(await appModuleEventually { await c.readySources == [.microphone] })
        await c.recordDiscontinuity(scope: f.scope(f.mic),reason: .deviceInterruption)
        try #require(await appModuleEventually { await c.streamState(source: .microphone)?.replacementReady == true })
        let fresh = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        await t.setReplacementReply(.rejected(.unavailable))
        #expect(try await c.replaceEpoch(scope: f.scope(f.mic),epoch: fresh) == false)
        await t.setReplacementReply(.accepted)
        try #require(await appModuleEventually { await c.streamState(source: .microphone)?.replacementReady == true })
        #expect(try await c.replaceEpoch(scope: f.scope(f.mic),epoch: fresh))
        #expect(await t.replacementStarts == 2)
        #expect(await c.streamState(source: .microphone)?.epoch.id == fresh.id)
        #expect(!(await store.projection().isClosed))
    }

    @Test(arguments: [false,true], [false,true])
    func FailedFreshSourceUsesDirectFallbackAndRetainsOnlyHistoricalResidency(loadedInitially: Bool, reactivate: Bool) async throws {
        let f = AppModuleFixture(), t = AppModuleTransport()
        let (c,store,resources) = try await f.coordinator(t)
        defer { Task { await c.retire() } }
        try await c.start()
        let context = loadedInitially ? UUID() : nil
        if let context {
            await f.activate(f.mic,transport: t,context: context)
            await t.emit(f.event(f.mic,3,.vad(.degraded(identity: f.vad.identity,contextID: context,sampleEnd: 0))))
        } else {
            await t.emit(f.event(f.mic,0,.vad(.preparing(identity: f.vad.identity))))
            await t.emit(f.event(f.mic,1,.vad(.degraded(identity: f.vad.identity,contextID: nil,sampleEnd: 0))))
            await t.emit(f.event(f.mic,2,.ready(generation: UUID(),originSample: 0)))
        }
        try #require(await appModuleEventually { await c.readySources == [.microphone] })
        await c.recordDiscontinuity(scope: f.scope(f.mic),reason: .deviceInterruption)
        await t.emit(f.event(f.mic,loadedInitially ? 4 : 3,.vad(.retired(identity: f.vad.identity,contextID: context,sampleEnd: 0))))
        try #require(await appModuleEventually { await c.streamState(source: .microphone)?.replacementReady == true })
        let fresh = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        await t.setReplacementEvents([
            f.event(fresh,0,.vad(reactivate ? .preparing(identity: f.vad.identity) : .degraded(identity: f.vad.identity,contextID: nil,sampleEnd: 0))),
            f.event(fresh,1,.ready(generation: UUID(),originSample: 0))
        ])
        _ = try await c.replaceEpoch(scope: f.scope(f.mic),epoch: fresh)
        if reactivate {
            #expect(await appModuleEventually { await store.projection().isClosed })
            #expect(await c.readySources.isEmpty)
        } else {
            #expect(await appModuleEventually { await c.readySources == [.microphone] })
            #expect(!(await store.projection().isClosed))
            #expect(await appModuleEventually {
                await resources.decide(.localChat(model: "fixture-chat"),measurement: .init(availableBytes: 400,pressure: .normal)) == (loadedInitially ? .admitted : .deferred)
            })
            // Retired old-scope frames cannot change the accepted fresh owner.
            await t.emit(f.event(f.mic,99,.vad(.preparing(identity: f.vad.identity))))
            #expect(await c.offer(scope: f.scope(fresh),samples: [0.25]) == .scheduled)
        }
    }

    @Test(arguments: ["identity","context","partial-window","skipped-window","duplicate-ready","duplicate-preparing","retirement-frontier","after-retired","after-failure","duplicate-window"])
    func InvalidModuleFactsFailBeforePublishingEvidenceOrReturningCredits(mode: String) async throws {
        let f = AppModuleFixture(), t = AppModuleTransport(), context = UUID()
        let (c,store,_) = try await f.coordinator(t)
        defer { Task { await c.retire() } }
        try await c.start(); await f.activate(f.mic,transport: t,context: context)
        try #require(await appModuleEventually { await c.readySources == [.microphone] })
        #expect(await c.offer(scope: f.scope(f.mic),samples: Array(repeating: 0.25,count: 3200)) == .scheduled)
        #expect(await c.offer(scope: f.scope(f.mic),samples: Array(repeating: 0.5,count: 896)) == .scheduled)
        try #require(await appModuleEventually { await t.requests.count == 2 })
        await t.emit(f.event(f.mic,3,.admitted(packetSequence: 0,sampleEnd: 3200)))
        await t.emit(f.event(f.mic,4,.admitted(packetSequence: 1,sampleEnd: 4096)))
        await t.emit(f.event(f.mic,5,.progress(.init(capturedSampleEnd: 4096,admittedSampleEnd: 4096,consumedSampleEnd: 0,
            queuedSamples: 0,inFlightSamples: 0,heldSamples: 4096,creditSamples: 45824,asrConsumedSampleEnd: 0))))
        try #require(await appModuleEventually { await store.projection().lanes.first?.progress.admittedSampleEnd == 4096 })
        var sequence: UInt64 = 6
        let bad: LiveVADModuleEvent
        switch mode {
        case "identity": bad = .processed(identity: .init(modelRevision: "silero-r1",modelFingerprint: String(repeating: "b",count: 64),
            runtimeRevision: "21493f8dac5a97e65742e6ff26f42f164c2fda0f"),contextID: context,sampleEnd: 4096)
        case "context": bad = .processed(identity: f.vad.identity,contextID: UUID(),sampleEnd: 4096)
        case "partial-window": bad = .processed(identity: f.vad.identity,contextID: context,sampleEnd: 4095)
        case "skipped-window": bad = .processed(identity: f.vad.identity,contextID: context,sampleEnd: 8192)
        case "duplicate-ready": bad = .ready(identity: f.vad.identity,contextID: context,originSample: 0)
        case "duplicate-preparing": bad = .preparing(identity: f.vad.identity)
        case "retirement-frontier": bad = .retired(identity: f.vad.identity,contextID: context,sampleEnd: 4096)
        case "after-retired":
            await t.emit(f.event(f.mic,sequence,.vad(.retired(identity: f.vad.identity,contextID: context,sampleEnd: 0)))); sequence += 1
            bad = .processed(identity: f.vad.identity,contextID: context,sampleEnd: 4096)
        case "after-failure":
            await t.emit(f.event(f.mic,sequence,.vad(.degraded(identity: f.vad.identity,contextID: context,sampleEnd: 0)))); sequence += 1
            bad = .ready(identity: f.vad.identity,contextID: context,originSample: 0)
        default:
            await t.emit(f.event(f.mic,sequence,.vad(.processed(identity: f.vad.identity,contextID: context,sampleEnd: 4096)))); sequence += 1
            bad = .processed(identity: f.vad.identity,contextID: context,sampleEnd: 4096)
        }
        await t.emit(f.event(f.mic,sequence,.vad(bad)))
        #expect(await appModuleEventually { await store.projection().isClosed })
        #expect(await store.projection().segments.isEmpty)
        #expect(await store.projection().lanes.first?.progress.consumedSampleEnd == 0)
    }

    @Test(arguments: [false,true])
    func ReplacementPreflightAbandonmentCannotDispatchAndKeepsThePeerAlive(newCut: Bool) async throws {
        let f = AppModuleFixture(), t = AppModuleTransport(), gate = AppModulePreflightGate()
        let store = LiveTranscriptStore(identity: f.identity)
        let c = LiveCaptureSessionCoordinator(input: f.input(both: true,configured: false),store: store,transport: await t.transport(),
            storeAccess: .init(admit: { await store.admit($0) },checkEpoch: { await gate.check(owner: $0,epoch: $1,store: store) }))
        defer { Task { await gate.release(); await c.retire() } }
        try await c.start()
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        await t.emit(f.event(f.system,0,.ready(generation: UUID(),originSample: 0)))
        try #require(await appModuleEventually { await c.readySources.count == 2 })
        await c.recordDiscontinuity(scope: f.scope(f.mic),reason: .deviceInterruption)
        try #require(await appModuleEventually { await c.streamState(source: .microphone)?.replacementReady == true })
        let fresh = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        let replacing = Task { try await c.replaceEpoch(scope: f.scope(f.mic),epoch: fresh) }
        try #require(await appModuleEventually { await gate.arrivals == [fresh.id] })
        if newCut { await c.recordDiscontinuity(scope: f.scope(f.mic),reason: .overload) }
        else { await c.abandonSource(scope: f.scope(f.mic)) }
        await gate.release()
        #expect(try await replacing.value == false)
        #expect(await t.replacementReturns == 0)
        #expect(await c.readySources == [.system])
        #expect(await c.offer(scope: f.scope(f.system),samples: [0.5]) == .scheduled)
        #expect(!(await store.projection().isClosed))
    }

    @Test(arguments: [false,true])
    func ConcurrentReplacementReservesTheLastSlotAndProposedUUIDBeforePreflight(duplicateUUID: Bool) async throws {
        let f = AppModuleFixture(), t = AppModuleTransport(), gate = AppModulePreflightGate()
        let store = LiveTranscriptStore(identity: f.identity)
        let c = LiveCaptureSessionCoordinator(input: f.input(both: true,configured: false),store: store,transport: await t.transport(),
            storeAccess: .init(admit: { await store.admit($0) },checkEpoch: { await gate.check(owner: $0,epoch: $1,store: store) }),
            epochHistoryLimit: duplicateUUID ? 4 : 3)
        defer { Task { await gate.release(); await c.retire() } }
        try await c.start()
        for epoch in [f.mic,f.system] {
            await t.emit(f.event(epoch,0,.ready(generation: UUID(),originSample: 0)))
        }
        try #require(await appModuleEventually { await c.readySources.count == 2 })
        for epoch in [f.mic,f.system] { await c.recordDiscontinuity(scope: f.scope(epoch),reason: .deviceInterruption) }
        try #require(await appModuleEventually {
            let mic = await c.streamState(source: .microphone), system = await c.streamState(source: .system)
            return mic?.replacementReady == true && system?.replacementReady == true
        })
        let fresh = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        let replacing = Task { try await c.replaceEpoch(scope: f.scope(f.mic),epoch: fresh) }
        try #require(await appModuleEventually { await gate.arrivals == [fresh.id] })
        let peer = LiveEpoch(id: duplicateUUID ? fresh.id : UUID(),source: .system,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        #expect(try await c.replaceEpoch(scope: f.scope(f.system),epoch: peer) == false)
        #expect(await gate.arrivals == [fresh.id])
        #expect(await t.replacementReturns == 0)
        await gate.release()
        #expect(try await replacing.value)
        #expect(await t.replacementReturns == 1)
        #expect(await c.streamState(source: .microphone)?.epoch.id == fresh.id)
        #expect(await c.streamState(source: .system)?.epoch.id == f.system.id)
    }

    @Test(arguments: [3,4])
    func AcceptedButAbandonedInstallationPreservesUUIDHistoryAndBudget(limit: Int) async throws {
        let f = AppModuleFixture(), t = AppModuleTransport()
        let ingress = LiveCaptureIngress(input: f.input(both: true))
        let (c,store,_) = try await f.coordinator(t,both: true,ingress: ingress,epochHistoryLimit: limit)
        defer { Task { await c.retire() } }
        try await c.start()
        let micContext = UUID(), systemContext = UUID()
        await f.activate(f.mic,transport: t,context: micContext)
        await f.activate(f.system,transport: t,context: systemContext)
        try #require(await appModuleEventually { await c.readySources.count == 2 })
        let metadata = LiveAudioMetadata(sourceEpoch: UUID(),role: .mic,timestamp: .unavailable,
            emittedFrames: .init(startFrame: 0,frameCount: 1600,sampleRate: 16000),writeOutcome: .failed,converter: nil)
        let raw = try #require(ingress.reserveRaw(source: .microphone,metadata: metadata,frames: 1600,rate: 16000,bytes: 6400))
        defer { withExtendedLifetime(raw) {} }
        _ = try #require(ingress.pauseAdmission(source: .microphone))
        for (epoch,context) in [(f.mic,micContext),(f.system,systemContext)] {
            await c.recordDiscontinuity(scope: f.scope(epoch),reason: .deviceInterruption)
            await t.emit(f.event(epoch,3,.vad(.retired(identity: f.vad.identity,contextID: context,sampleEnd: 0))))
        }
        try #require(await appModuleEventually {
            let mic = await c.streamState(source: .microphone), system = await c.streamState(source: .system)
            return mic?.replacementReady == true && system?.replacementReady == true
        })
        let fresh = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        let replacing = Task { try await c.replaceEpoch(scope: f.scope(f.mic),epoch: fresh) }
        try #require(await appModuleEventually { await t.replacementReturns == 1 })
        await c.abandonSource(scope: f.scope(f.mic))
        #expect(try await replacing.value == false)
        let duplicate = LiveEpoch(id: fresh.id,source: .system,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        #expect(try await c.replaceEpoch(scope: f.scope(f.system),epoch: duplicate) == false)
        #expect(await t.replacementReturns == 1)
        let peer = LiveEpoch(id: UUID(),source: .system,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        #expect(try await c.replaceEpoch(scope: f.scope(f.system),epoch: peer) == (limit == 4))
        #expect(await t.replacementReturns == (limit == 4 ? 2 : 1))
        #expect(ingress.statistics(.microphone).rawBytes == 6400)
        #expect(!(await store.projection().isClosed))
    }

    @Test(arguments: [false,true])
    func OriginalAdmissionsBoundProcessedModuleFactsEvenAfterRepeatedLocalCuts(afterCut: Bool) async throws {
        let f = AppModuleFixture(), t = AppModuleTransport(), context = UUID()
        let (c,store,_) = try await f.coordinator(t,both: true)
        defer { Task { await c.retire() } }
        try await c.start()
        await f.activate(f.mic,transport: t,context: context)
        await f.activate(f.system,transport: t)
        try #require(await appModuleEventually { await c.readySources.count == 2 })
        #expect(await c.offer(scope: f.scope(f.mic),samples: Array(repeating: 0.25,count: 3200)) == .scheduled)
        #expect(await c.offer(scope: f.scope(f.mic),samples: Array(repeating: 0.5,count: 896)) == .scheduled)
        try #require(await appModuleEventually { await t.requests.count == 2 })
        if afterCut {
            await c.recordDiscontinuity(scope: f.scope(f.mic),reason: .deviceInterruption)
            await c.recordDiscontinuity(scope: f.scope(f.mic),reason: .deviceInterruption)
            try #require(await appModuleEventually { await t.requests.count >= 3 })
            #expect(await c.streamState(source: .microphone)?.replacementReady == false)
        }
        await t.emit(f.event(f.mic,3,.admitted(packetSequence: 0,sampleEnd: 3200)))
        await t.emit(f.event(f.mic,4,.admitted(packetSequence: 1,sampleEnd: 4096)))
        await t.emit(f.event(f.mic,5,.vad(.processed(identity: f.vad.identity,contextID: context,sampleEnd: 4096))))
        await t.emit(f.event(f.mic,6,.vad(.retired(identity: f.vad.identity,contextID: context,sampleEnd: 4096))))
        if !afterCut { await c.recordDiscontinuity(scope: f.scope(f.mic),reason: .deviceInterruption) }
        try #require(await appModuleEventually { await c.streamState(source: .microphone)?.replacementReady == true })
        await c.synchronizeStore()
        let display = await store.projection()
        #expect(!display.isClosed && display.segments.isEmpty)
        #expect(display.lanes.first { $0.epoch.source == .microphone }?.progress.consumedSampleEnd == 0)
        if afterCut { #expect(display.lanes.first { $0.epoch.source == .microphone }?.progress.admittedSampleEnd == 0) }
        #expect(display.coverage.first?.kind == .gap(.deviceInterruption))
        #expect(await c.readySources == [.system])
        #expect(await c.offer(scope: f.scope(f.system),samples: [0.75]) == .scheduled)
        let fresh = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        #expect(try await c.replaceEpoch(scope: f.scope(f.mic),epoch: fresh))
        await f.activate(fresh,transport: t)
        #expect(await appModuleEventually { await c.readySources.count == 2 })
    }

    @Test(arguments: [false,true])
    func ProgressCannotCreateOriginalModuleAdmissionBeforeOrAfterCut(afterCut: Bool) async throws {
        let f = AppModuleFixture(), t = AppModuleTransport()
        let (c,store,_) = try await f.coordinator(t)
        defer { Task { await c.retire() } }
        try await c.start(); await f.activate(f.mic,transport: t)
        try #require(await appModuleEventually { await c.readySources == [.microphone] })
        #expect(await c.offer(scope: f.scope(f.mic),samples: Array(repeating: 0.25,count: 3200)) == .scheduled)
        #expect(await c.offer(scope: f.scope(f.mic),samples: Array(repeating: 0.5,count: 896)) == .scheduled)
        try #require(await appModuleEventually { await t.requests.count == 2 })
        if afterCut { await c.recordDiscontinuity(scope: f.scope(f.mic),reason: .deviceInterruption) }
        // These numeric credits are otherwise valid, but no original admission
        // receipt has acknowledged either dispatched packet.
        await t.emit(f.event(f.mic,3,.progress(f.progress(4096))))
        #expect(await appModuleEventually { await store.projection().isClosed })
        let display = await store.projection()
        #expect(display.lanes.first?.progress.consumedSampleEnd == 0)
        #expect(display.lanes.first?.progress.admittedSampleEnd == 0)
    }

    @Test(arguments: [false,true])
    func PauseRequiresOrderedModuleRetirementAndInstallsThePreReplyFreshInbox(retireFirst: Bool) async throws {
        let f = AppModuleFixture(), t = AppModuleTransport(), context = UUID()
        let (c,store,_) = try await f.coordinator(t,both: true)
        defer { Task { await t.release(); await c.retire() } }
        try await c.start(); await f.activate(f.mic,transport: t,context: context)
        await f.activate(f.system,transport: t)
        try #require(await appModuleEventually { await c.readySources.count == 2 })
        #expect(await c.requestPauseBoundary(scope: f.scope(f.mic)))
        try #require(await appModuleEventually { await t.requests.count == 1 })
        var sequence: UInt64 = 3
        if retireFirst {
            await t.emit(f.event(f.mic,sequence,.vad(.retired(identity: f.vad.identity,contextID: context,sampleEnd: 0))))
            sequence += 1
        }
        let pause = try #require(await t.requests.compactMap { if case .barrier(let b) = $0 { return b }; return nil }.first)
        #expect(pause == .init(scope: f.scope(f.mic),nextPacketSequence: 0,sampleEnd: 0,kind: .pause))
        await t.emit(f.event(f.mic,sequence,.barrierCompleted(requestID: UUID(),kind: .pause,sampleEnd: 0)))
        if !retireFirst {
            #expect(await appModuleEventually { await store.projection().isClosed })
            #expect(await c.pausedSources.isEmpty)
            return
        }
        try #require(await appModuleEventually { await c.pausedSources == [.microphone] })
        try #require(await appModuleEventually { await c.streamState(source: .microphone)?.replacementReady == true })
        #expect(await c.offer(scope: f.scope(f.system),samples: [0.5]) == .scheduled)
        try #require(await appModuleEventually { await t.requests.count == 2 })
        await t.emit(f.event(f.system,3,.admitted(packetSequence: 0,sampleEnd: 1)))
        await t.emit(f.event(f.system,4,.progress(.init(capturedSampleEnd: 1,admittedSampleEnd: 1,consumedSampleEnd: 0,
            queuedSamples: 0,inFlightSamples: 0,heldSamples: 1,creditSamples: 49919,asrConsumedSampleEnd: 1))))
        let fresh = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        await t.setReplacementEvents([
            f.event(fresh,0,.vad(.preparing(identity: f.vad.identity))),
            f.event(fresh,1,.vad(.ready(identity: f.vad.identity,contextID: UUID(),originSample: 0))),
            f.event(fresh,2,.ready(generation: UUID(),originSample: 0)),
            f.event(f.system,5,.partial(.init(epochID: f.system.id,source: .system,revision: 0,
                samples: .init(start: 0,end: 1),text: "Healthy peer observed the pre-reply inbox")))
        ])
        await t.blockReplyAfterEvents(.microphone)
        let replacing = Task { try await c.replaceEpoch(scope: f.scope(f.mic),epoch: fresh) }
        try #require(await appModuleEventually { await store.projection().partials.first?.text == "Healthy peer observed the pre-reply inbox" })
        #expect(await t.replacementReturns == 0)
        #expect(await c.streamState(source: .microphone)?.epoch.id == f.mic.id)
        #expect(await c.readySources == [.system])
        await t.releaseReplacement()
        #expect(try await replacing.value)
        #expect(await appModuleEventually { await c.readySources.count == 2 })
        #expect(await c.streamState(source: .microphone)?.epoch.id == fresh.id)
        #expect(!(await store.projection().isClosed))
    }

    @Test(arguments: [false,true])
    func FinishDuringPreparationRequiresRetiredMetadataBeforeTerminalFacts(retireFirst: Bool) async throws {
        let f = AppModuleFixture(), t = AppModuleTransport()
        let (c,store,_) = try await f.coordinator(t)
        defer { Task { await c.retire() } }
        try await c.start()
        // This case exercises Finish after Begin was actually invoked, while
        // VAD remains unready. Stop winning before invocation has no helper
        // stream to finish and is covered by the undispatched EOF regression.
        try #require(await appModuleEventually { await t.starts == 1 })
        await c.beginClosing(); await c.hardwareDidClose()
        try #require(await appModuleEventually { await t.requests.count == 1 })
        let finish = try #require(await t.requests.compactMap { if case .barrier(let b) = $0 { return b }; return nil }.first)
        var sequence: UInt64 = 0
        if retireFirst {
            await t.emit(f.event(f.mic,sequence,.vad(.retired(identity: f.vad.identity,contextID: nil,sampleEnd: 0))))
            sequence += 1
        }
        #expect(finish == .init(scope: f.scope(f.mic),nextPacketSequence: 0,sampleEnd: 0,kind: .finish))
        await t.emit(f.event(f.mic,sequence,.barrierCompleted(requestID: UUID(),kind: .finish,sampleEnd: 0)))
        if !retireFirst {
            #expect(await appModuleEventually { await store.projection().isClosed })
            #expect(await c.streamState(source: .microphone) == nil)
            return
        }
        await t.emit(f.event(f.mic,sequence+1,.closed(sampleEnd: 0)))
        await t.emit(.finished(f.identity))
        try await c.waitUntilClosed()
        #expect(await store.projection().isClosed)
    }

    @Test func orderedModuleReadinessOpensBothSourcesAndProvesTheResidentPool() async throws {
        let f = AppModuleFixture(), t = AppModuleTransport()
        let (c,store,resources) = try await f.coordinator(t,both: true)
        defer { Task { await t.release(); await c.retire() } }
        try await c.start()
        try #require(await appModuleEventually { await t.starts == 1 })
        await f.activate(f.mic,transport: t)
        try #require(await appModuleEventually { await c.readySources == [.microphone] })
        #expect(!(await store.projection().isClosed))
        #expect(await resources.decide(.localChat(model: "fixture-chat"),measurement: .init(availableBytes: 400,pressure: .normal)) == .deferred)
        await f.activate(f.system,transport: t)
        try #require(await appModuleEventually { await c.readySources.count == 2 })
        #expect(await appModuleEventually {
            await resources.decide(.localChat(model: "fixture-chat"),measurement: .init(availableBytes: 400,pressure: .normal)) == .admitted
        })
        #expect(await resources.reservedBytes == 520)
        #expect(await c.offer(scope: f.scope(f.mic),samples: [0.25]) == .scheduled)
        #expect(await c.offer(scope: f.scope(f.system),samples: [0.5]) == .scheduled)
    }

    @Test func ASRReadinessCannotOpenAConfiguredSourceBeforeModuleActivation() async throws {
        let f = AppModuleFixture(), t = AppModuleTransport()
        let (c,store,_) = try await f.coordinator(t)
        defer { Task { await c.retire() } }
        try await c.start()
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        #expect(await appModuleEventually { await store.projection().isClosed })
        #expect(await c.readySources.isEmpty)
        #expect(await c.offer(scope: f.scope(f.mic),samples: [0.25]) == .rejected)
    }

    @Test func LoadingFallbackOpensASRWithoutManufacturingVADResidency() async throws {
        let f = AppModuleFixture(), t = AppModuleTransport()
        let (c,store,resources) = try await f.coordinator(t)
        defer { Task { await c.retire() } }
        try await c.start()
        await t.emit(f.event(f.mic,0,.vad(.preparing(identity: f.vad.identity))))
        await t.emit(f.event(f.mic,1,.vad(.degraded(identity: f.vad.identity,contextID: nil,sampleEnd: 0))))
        await t.emit(f.event(f.mic,2,.ready(generation: UUID(),originSample: 0)))
        try #require(await appModuleEventually { await c.readySources == [.microphone] })
        #expect(!(await store.projection().isClosed))
        try #require(await appModuleEventually {
            await resources.decide(.localChat(model: "fixture-chat"),measurement: .init(availableBytes: 520,pressure: .normal)) == .admitted
        })
        #expect(await resources.decide(.localChat(model: "fixture-chat"),measurement: .init(availableBytes: 400,pressure: .normal)) == .deferred)
        #expect(await c.offer(scope: f.scope(f.mic),samples: [0.25]) == .scheduled)
    }

    @Test func HistoricalVADReadinessSurvivesDegradationAndIsChargedUntilActualExit() async throws {
        let f = AppModuleFixture(), t = AppModuleTransport()
        let (c,store,resources) = try await f.coordinator(t)
        await t.blockTeardown()
        defer { Task { await t.release(); await c.retire() } }
        try await c.start()
        let context = UUID()
        await f.activate(f.mic,transport: t,context: context)
        try #require(await appModuleEventually { await c.readySources == [.microphone] })
        await t.emit(f.event(f.mic,3,.vad(.degraded(identity: f.vad.identity,contextID: context,sampleEnd: 0))))
        #expect(await appModuleEventually {
            await resources.decide(.localChat(model: "fixture-chat"),measurement: .init(availableBytes: 400,pressure: .normal)) == .admitted
        })
        #expect(!(await store.projection().isClosed))
        await c.retire()
        try #require(await appModuleEventually { await t.shutdowns == 1 })
        #expect(await resources.reservedBytes == 520)
        await t.release()
        #expect(await appModuleEventually { await resources.reservedBytes == 0 })
    }

    @Test func InternalReadyPreservesTheExactReservedExternalBoundaryAndFutureDispatchGate() async throws {
        let f = AppModuleFixture(), t = AppModuleTransport()
        let (c,store,_) = try await f.coordinator(t,configured: false)
        defer { Task { await c.retire() } }
        try await c.start()
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        try #require(await appModuleEventually { await c.readySources == [.microphone] })
        var sequence: UInt64 = 1
        for index in 0..<75 {
            #expect(await c.offer(scope: f.scope(f.mic),samples: Array(repeating: 0.25,count: 3200)) == .scheduled)
            let end = Int64(index+1)*3200
            try #require(await appModuleEventually { await t.requests.count >= index+1 })
            await t.emit(f.event(f.mic,sequence,.admitted(packetSequence: UInt64(index),sampleEnd: end))); sequence += 1
            await t.emit(f.event(f.mic,sequence,.progress(f.progress(end)))); sequence += 1
            try #require(await appModuleEventually { await store.projection().lanes.first?.progress.consumedSampleEnd == end })
        }
        try #require(await appModuleEventually { await t.requests.count == 76 })
        let boundary = try #require(await t.requests.compactMap { if case .barrier(let b) = $0 { return b }; return nil }.first)
        #expect(boundary == .init(scope: f.scope(f.mic),nextPacketSequence: 75,sampleEnd: 240000,kind: .utterance))
        await t.emit(f.event(f.mic,sequence,.settled(.init(epochID: f.mic.id,source: .microphone,
            range: .init(samples: .init(start: 0,end: 16384),meeting: nil),kind: .gap(.unavailable))))); sequence += 1
        await t.emit(f.event(f.mic,sequence,.ready(generation: UUID(),originSample: 16384))); sequence += 1
        await t.emit(f.event(f.mic,sequence,.partial(.init(epochID: f.mic.id,source: .microphone,revision: 0,
            samples: .init(start: 16384,end: 16385),text: "Internal ready observed behind the reserved boundary")))); sequence += 1
        try #require(await appModuleEventually { await store.projection().partials.first?.text == "Internal ready observed behind the reserved boundary" })
        #expect(await c.maximumPacketSamples(scope: f.scope(f.mic)) == 3200)
        #expect(await c.offer(scope: f.scope(f.mic),samples: Array(repeating: 0.5,count: 3200)) == .scheduled)
        #expect(await t.requests.count == 76)
        await t.emit(f.event(f.mic,sequence,.settled(.init(epochID: f.mic.id,source: .microphone,
            range: .init(samples: .init(start: 16384,end: 240000),meeting: nil),kind: .gap(.unavailable))))); sequence += 1
        await t.emit(f.event(f.mic,sequence,.barrierCompleted(requestID: UUID(),kind: .utterance,sampleEnd: 240000))); sequence += 1
        try #require(await appModuleEventually { await t.requests.count == 77 })
        let next = try #require(await t.requests.compactMap { if case .packet(let p) = $0 { return p }; return nil }.last)
        #expect(next.sequence == 75 && next.startSample == 240000 && next.sampleCount == 3200)
        #expect(await store.projection().lanes.first?.progress.admittedSampleEnd == 240000)
    }

    @Test func InternalASRResetMovesTheNextFifteenSecondBoundaryToTheNewOrigin() async throws {
        let f = AppModuleFixture(), t = AppModuleTransport()
        let (c,store,_) = try await f.coordinator(t,configured: false)
        defer { Task { await c.retire() } }
        try await c.start()
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        try #require(await appModuleEventually { await c.readySources == [.microphone] })
        var sequence: UInt64 = 1, packetSequence: UInt64 = 0, end: Int64 = 0
        for count in [3200,3200,3200,3200,3200,384] {
            #expect(await c.offer(scope: f.scope(f.mic),samples: Array(repeating: 0.25,count: count)) == .scheduled)
            end += Int64(count)
            let dispatched = packetSequence + 1
            try #require(await appModuleEventually { await t.requests.count == Int(dispatched) })
            await t.emit(f.event(f.mic,sequence,.admitted(packetSequence: packetSequence,sampleEnd: end))); sequence += 1
            await t.emit(f.event(f.mic,sequence,.progress(f.progress(end)))); sequence += 1
            let currentEnd = end
            try #require(await appModuleEventually { await store.projection().lanes.first?.progress.consumedSampleEnd == currentEnd })
            packetSequence += 1
        }
        #expect(end == 16384)
        await t.emit(f.event(f.mic,sequence,.settled(.init(epochID: f.mic.id,source: .microphone,
            range: .init(samples: .init(start: 0,end: 16384),meeting: nil),kind: .gap(.unavailable))))); sequence += 1
        await t.emit(f.event(f.mic,sequence,.ready(generation: UUID(),originSample: 16384))); sequence += 1
        try #require(await appModuleEventually { await store.projection().coverage.first?.range.samples?.end == 16384 })
        for _ in 0..<75 {
            // Exactly 240000 new samples follow the internal decoder reset.
            try #require(await c.maximumPacketSamples(scope: f.scope(f.mic)) == 3200)
            #expect(await c.offer(scope: f.scope(f.mic),samples: Array(repeating: 0.5,count: 3200)) == .scheduled)
            end += 3200
            let dispatched = packetSequence + 1
            try #require(await appModuleEventually { await t.requests.count >= Int(dispatched) })
            await t.emit(f.event(f.mic,sequence,.admitted(packetSequence: packetSequence,sampleEnd: end))); sequence += 1
            await t.emit(f.event(f.mic,sequence,.progress(f.progress(end)))); sequence += 1
            let currentEnd = end
            try #require(await appModuleEventually { await store.projection().lanes.first?.progress.consumedSampleEnd == currentEnd })
            packetSequence += 1
        }
        #expect(end == 256384)
        try #require(await appModuleEventually { await t.requests.contains { if case .barrier = $0 { return true }; return false } })
        let barriers = await t.requests.compactMap { if case .barrier(let b) = $0 { return b }; return nil }
        #expect(barriers.map(\.sampleEnd) == [256384])
        #expect(barriers.first?.nextPacketSequence == 81)
    }
}
