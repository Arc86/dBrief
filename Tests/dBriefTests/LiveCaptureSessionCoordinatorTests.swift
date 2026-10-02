import Foundation
import Testing
import dBriefWire
@testable import dBrief

private actor CaptureTransportFixture {
    let stream: AsyncThrowingStream<LiveSessionEvent, Error>
    let output: AsyncThrowingStream<LiveSessionEvent, Error>.Continuation
    var requests: [LiveSessionRequest] = []
    var starts = 0
    var shutdowns = 0
    var holdShutdown = false
    var holdBegin = false
    var holdCommand = false
    var rejectReplacement = false
    var beginWaiter: CheckedContinuation<Void, Never>?
    var commandWaiter: CheckedContinuation<Void, Never>?
    var shutdownWaiter: CheckedContinuation<Void, Never>?
    init() { (stream,output) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(128)) }
    func begin(_ input: LiveSessionBegin) async -> AsyncThrowingStream<LiveSessionEvent, Error> {
        starts += 1
        if holdBegin { await withCheckedContinuation { beginWaiter = $0 } }
        return stream
    }
    func command(_ request: LiveSessionRequest) async -> LiveSessionReply {
        requests.append(request)
        if holdCommand { await withCheckedContinuation { commandWaiter = $0 } }
        if case .replaceEpoch(let identity,_,let epoch) = request {
            if rejectReplacement { return .rejected(.unavailable) }
            let scope = LiveLaneScope(identity: identity,source: epoch.source,epochID: epoch.id)
            output.yield(.lane(.init(scope: scope,sequence: 0,payload: .ready(generation: UUID(),originSample: 0))))
            // Readiness can precede the command acknowledgment over IPC.
            output.yield(.lane(.init(scope: scope,sequence: 1,payload: .progress(.init(capturedSampleEnd: 0,admittedSampleEnd: 0,consumedSampleEnd: 0,queuedSamples: 0,inFlightSamples: 0,heldSamples: 0,creditSamples: 49920)))))
        }
        return .accepted
    }
    func shutdown() async { shutdowns += 1; if holdShutdown { await withCheckedContinuation { shutdownWaiter = $0 } } }
    func configure(begin: Bool = false, command: Bool = false) { holdBegin = begin; holdCommand = command }
    func release() { holdBegin = false; holdCommand = false; holdShutdown = false; beginWaiter?.resume(); beginWaiter = nil; commandWaiter?.resume(); commandWaiter = nil; shutdownWaiter?.resume(); shutdownWaiter = nil }
    func holdTeardown() { holdShutdown = true }
    func rejectReplacements(_ value: Bool) { rejectReplacement = value }
    func emit(_ event: LiveSessionEvent) { output.yield(event) }
    func transport() -> LiveASRTransport {
        .init(begin: { await self.begin($0) }, command: { await self.command($0) }, deadline: { _ in }, shutdown: { await self.shutdown() })
    }
}

private struct CaptureCoordinatorFixture {
    let identity = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
    let mic = LiveEpoch(id: UUID(), source: .microphone, engineRevision: "fixture", language: "auto", meetingOriginNanoseconds: nil)
    let system = LiveEpoch(id: UUID(), source: .system, engineRevision: "fixture", language: "auto", meetingOriginNanoseconds: nil)
    func scope(_ epoch: LiveEpoch) -> LiveLaneScope { .init(identity: identity,source: epoch.source,epochID: epoch.id) }
    func event(_ epoch: LiveEpoch, _ seq: UInt64, _ payload: LiveLaneEvent.Payload) -> LiveSessionEvent {
        .lane(.init(scope: scope(epoch),sequence: seq,payload: payload))
    }
    func input(_ tier: Int = 1120, both: Bool = false) -> LiveSessionBegin {
        .init(identity: identity,configuration: .init(language: .auto,chunkMs: tier,modelDirectory: "/fixture"),epochs: both ? [mic,system] : [mic])
    }
    func coordinator(_ transport: CaptureTransportFixture, tier: Int = 1120, both: Bool = false) async -> (LiveCaptureSessionCoordinator,LiveTranscriptStore) {
        let store = LiveTranscriptStore(identity: identity)
        return (LiveCaptureSessionCoordinator(input: input(tier,both: both),store: store,transport: await transport.transport(),drainDeadline: .milliseconds(60)),store)
    }
}

private func captureEventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<100 { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(2)) }
    return false
}

private actor CapturePublicationGate {
    var blocked = false
    var waiter: CheckedContinuation<Void, Never>?
    func admit(_ event: LiveTranscriptEvent, store: LiveTranscriptStore) async -> LiveStoreAdmission {
        if case .committed(let segment) = event.payload, segment.text == "Conflicting ID" {
            blocked = true; await withCheckedContinuation { waiter = $0 }
        }
        return await store.admit(event)
    }
    func release() { waiter?.resume(); waiter = nil }
}

@Suite struct LiveCaptureSessionCoordinatorTests {
    @Test func sharedIngressTransfersActualConsumedCreditsAndRetainsCutNativeUntilReplacement() async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture(), store = LiveTranscriptStore(identity: f.identity)
        let input = f.input(), ingress = LiveCaptureIngress(input: input)
        let c = LiveCaptureSessionCoordinator(input: input,store: store,transport: await t.transport(),ingress: ingress)
        try await c.start()
        #expect(await captureEventually { await t.starts == 1 })
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        #expect(await captureEventually { await c.readySources.count == 1 })
        let metadata = LiveAudioMetadata(sourceEpoch: UUID(),role: .mic,timestamp: .unavailable,
            emittedFrames: .init(startFrame: 0,frameCount: 3200,sampleRate: 16000),writeOutcome: .failed,converter: nil)
        let raw = try #require(ingress.reserveRaw(source: .microphone,metadata: metadata,frames: 3200,rate: 16000,bytes: 12800))
        let normalized = try #require(ingress.normalize(raw,scope: f.scope(f.mic),emittedSamples: 3200))
        #expect(await c.offer(scope: f.scope(f.mic),samples: [0]) == .rejected)
        #expect(await c.offer(scope: f.scope(f.mic),samples: [Float](repeating: 0,count: 3200),reservation: normalized) == .scheduled)
        #expect(await captureEventually { await t.requests.count == 1 })
        #expect(ingress.statistics(.microphone).nativeSamples == 3200)
        await t.emit(f.event(f.mic,1,.progress(.init(capturedSampleEnd: 3200,admittedSampleEnd: 3200,consumedSampleEnd: 1600,
            queuedSamples: 0,inFlightSamples: 0,heldSamples: 1600,creditSamples: 48320))))
        #expect(await captureEventually { ingress.statistics(.microphone).nativeSamples == 1600 })
        #expect(await store.projection().lanes.first?.settledSampleEnd == 0)
        await c.recordDiscontinuity(scope: f.scope(f.mic),reason: .overload)
        #expect(await captureEventually { await t.requests.contains { if case .cut = $0 { return true }; return false } })
        #expect(ingress.statistics(.microphone).nativeSamples == 1600)
        let epoch = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        #expect(await captureEventually { (try? await c.replaceEpoch(scope: f.scope(f.mic),epoch: epoch)) == true })
        #expect(ingress.statistics(.microphone).nativeSamples == 0)
        await c.retire(); try await c.waitUntilClosed()
    }

    @Test func consumedCreditsDoNotSettleAndOverloadPreservesOnlyTheCommittedPrefix() async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture(), (c,store) = await f.coordinator(t,tier: 560)
        try await c.start()
        #expect(await captureEventually { await t.starts == 1 })
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        #expect(await captureEventually { await c.readySources.count == 1 })
        for _ in 0..<5 { #expect(await c.offer(scope: f.scope(f.mic),samples: [Float](repeating: 0,count: 3200)) == .scheduled) }
        #expect(await captureEventually { await t.requests.count == 5 })
        await t.emit(f.event(f.mic,1,.progress(.init(capturedSampleEnd: 16000,admittedSampleEnd: 16000,consumedSampleEnd: 10000,queuedSamples: 0,inFlightSamples: 0,heldSamples: 6000,creditSamples: 34960))))
        #expect(await captureEventually { await store.projection().lanes.first?.progress.consumedSampleEnd == 10000 })
        #expect(await store.projection().lanes.first?.settledSampleEnd == 0)
        let prefix = CommittedLiveSegment(id: .init(epochID: f.mic.id,index: 0),source: .microphone,
            range: .init(samples: .init(start: 0,end: 6000),meeting: nil),text: "Committed prefix")
        await t.emit(f.event(f.mic,2,.committed(prefix)))
        #expect(await captureEventually { await store.projection().segments == [prefix] })
        var remainder = 34960
        while remainder > 0 {
            let count = min(3200,remainder)
            #expect(await c.offer(scope: f.scope(f.mic),samples: [Float](repeating: 0,count: count)) == .scheduled)
            remainder -= count
        }
        #expect(await c.offer(scope: f.scope(f.mic),samples: [0]) == .dropped)
        await c.synchronizeStore()
        #expect(await store.projection().segments == [prefix])
        #expect(await store.projection().coverage.contains { $0.kind == .gap(.overload) && $0.range.samples == .init(start: 6000,end: 50961) })
        await c.retire(); try await c.waitUntilClosed()
    }

    @Test func lateOldPreparationCannotAttachToOrShutDownANewCapture() async throws {
        let old = CaptureCoordinatorFixture(), oldTransport = CaptureTransportFixture()
        await oldTransport.configure(begin: true)
        let (oldCoordinator,oldStore) = await old.coordinator(oldTransport)
        try await oldCoordinator.start()
        #expect(await captureEventually { await oldTransport.starts == 1 })
        await oldCoordinator.retire(); try await oldCoordinator.waitUntilClosed()
        let before = await oldStore.snapshot()
        let new = CaptureCoordinatorFixture(), newTransport = CaptureTransportFixture()
        let (newCoordinator,newStore) = await new.coordinator(newTransport)
        try await newCoordinator.start()
        #expect(await captureEventually { await newTransport.starts == 1 })
        await newTransport.emit(new.event(new.mic,0,.ready(generation: UUID(),originSample: 0)))
        #expect(await captureEventually { await newCoordinator.readySources.count == 1 })
        await oldTransport.release(); await oldTransport.emit(old.event(old.mic,0,.ready(generation: UUID(),originSample: 0)))
        #expect(await captureEventually { await oldTransport.shutdowns >= 2 })
        #expect(await newTransport.shutdowns == 0)
        #expect(await oldStore.snapshot() == before)
        #expect(await newCoordinator.offer(scope: new.scope(new.mic),samples: [0]) == .scheduled)
        #expect(!((await newStore.projection()).isClosed))
        await newCoordinator.retire(); try await newCoordinator.waitUntilClosed()
    }

    @Test func closingClearsExistingPartialsWithoutChangingFrozenChatEvidence() async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture()
        let (c,store) = await f.coordinator(t)
        try await c.start()
        #expect(await captureEventually { await t.starts == 1 })
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        #expect(await captureEventually { await c.readySources.count == 1 })
        #expect(await c.offer(scope: f.scope(f.mic),samples: [0]) == .scheduled)
        #expect(await captureEventually { await t.requests.count == 1 })
        await t.emit(f.event(f.mic,1,.progress(.init(capturedSampleEnd: 1,admittedSampleEnd: 1,consumedSampleEnd: 0,queuedSamples: 0,inFlightSamples: 0,heldSamples: 1,creditSamples: 49919))))
        await t.emit(f.event(f.mic,2,.partial(.init(epochID: f.mic.id,source: .microphone,revision: 0,samples: .init(start: 0,end: 1),text: "Pending preview"))))
        #expect(await captureEventually { await store.projection().partials.count == 1 })
        let before = await store.snapshot()
        await c.beginClosing(); await c.synchronizeStore()
        #expect(await store.projection().partials.isEmpty)
        #expect(await store.snapshot() == before)
        await c.retire(); try await c.waitUntilClosed()
    }

    @Test func anchorBecomingStaleDuringReplacementDegradesOnlyItsClock() async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture(), store = LiveTranscriptStore(identity: f.identity)
        let mic = LiveEpoch(id: f.mic.id,source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: 0)
        let c = LiveCaptureSessionCoordinator(input: .init(identity: f.identity,configuration: f.input().configuration,epochs: [mic,f.system]),store: store,transport: await t.transport())
        try await c.start()
        #expect(await captureEventually { await t.starts == 1 })
        for epoch in [mic,f.system] { await t.emit(f.event(epoch,0,.ready(generation: UUID(),originSample: 0))) }
        #expect(await captureEventually { await c.readySources.count == 2 })
        #expect(await c.offer(scope: f.scope(mic),samples: [0]) == .scheduled)
        await c.recordDiscontinuity(scope: f.scope(mic),reason: .deviceInterruption)
        #expect(await captureEventually { await t.requests.contains { if case .cut = $0 { return true }; return false } })
        await c.synchronizeStore(); await t.configure(command: true)
        let new = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: 62500)
        let replacement = Task { try await c.replaceEpoch(scope: f.scope(mic),epoch: new) }
        #expect(await captureEventually { await t.requests.contains { if case .replaceEpoch = $0 { return true }; return false } })
        #expect(await c.offer(scope: f.scope(mic),samples: [0]) == .dropped)
        await c.synchronizeStore(); await t.release()
        #expect(try await replacement.value)
        await c.synchronizeStore()
        let projection = await store.projection()
        #expect(!projection.isClosed)
        #expect(projection.lanes.contains { $0.epoch.id == new.id && $0.epoch.meetingOriginNanoseconds == nil })
        #expect(await c.readySources.contains(.system))
        #expect(await c.offer(scope: f.scope(f.system),samples: [0]) == .scheduled)
        await c.retire(); try await c.waitUntilClosed()
    }

    @Test func rewoundReplacementIsDeniedBeforeNativeAndDoesNotRetireTheOtherLane() async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture(), store = LiveTranscriptStore(identity: f.identity)
        let mic = LiveEpoch(id: f.mic.id,source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: 0)
        let input = LiveSessionBegin(identity: f.identity,configuration: f.input().configuration,epochs: [mic,f.system])
        let c = LiveCaptureSessionCoordinator(input: input,store: store,transport: await t.transport())
        try await c.start()
        #expect(await captureEventually { await t.starts == 1 })
        for epoch in [mic,f.system] { await t.emit(f.event(epoch,0,.ready(generation: UUID(),originSample: 0))) }
        #expect(await captureEventually { await c.readySources.count == 2 })
        #expect(await c.offer(scope: f.scope(mic),samples: [0]) == .scheduled)
        await c.recordDiscontinuity(scope: f.scope(mic),reason: .deviceInterruption)
        #expect(await captureEventually { await t.requests.contains { if case .cut = $0 { return true }; return false } })
        let new = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: 0)
        // Current physical source time is 62,500ns; replacing at zero rewinds it.
        #expect(try await c.replaceEpoch(scope: f.scope(mic),epoch: new) == false)
        #expect(await t.requests.allSatisfy { if case .replaceEpoch = $0 { return false }; return true })
        #expect(await c.readySources == [.system])
        #expect(await c.offer(scope: f.scope(f.system),samples: [0]) == .scheduled)
        await c.retire(); try await c.waitUntilClosed()
    }

    @Test func resourceLeaseCannotAuthorizeADifferentModelRevision() async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture()
        let policy = LiveModelResourcePolicy(profiles: [.init(id: "fixture",hardware: "fixture",modelRevision: "qualified-other-model",chunkMs: 1120,sourceCount: 1,
            qualificationID: "model-free-test-only",asrBytes: 400,attributionBytes: nil,headroomBytes: 100,concurrentChatModels: [:],backgroundWorkQualified: false)])
        let lease = try await policy.admit(identity: f.identity,request: .init(profileID: "fixture",hardware: "fixture",modelRevision: "qualified-other-model",chunkMs: 1120,sourceCount: 1,attributionRequested: false),measurement: .init(availableBytes: 1000,pressure: .normal))
        let c = LiveCaptureSessionCoordinator(input: f.input(),store: LiveTranscriptStore(identity: f.identity),transport: await t.transport(),resources: policy,lease: lease)
        await #expect(throws: LiveProtocolError.invalidConfiguration) { try await c.start() }
        await c.retire(); try await c.waitUntilClosed()
    }

    @Test func failedPublicationReconcilesNewCaptureAgainstTheActualStoreFrontier() async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture(), gate = CapturePublicationGate()
        let store = LiveTranscriptStore(identity: f.identity)
        let c = LiveCaptureSessionCoordinator(input: f.input(),store: store,transport: await t.transport(),
            storeAccess: .init(admit: { await gate.admit($0,store: store) }))
        try await c.start()
        #expect(await captureEventually { await t.starts == 1 })
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        #expect(await captureEventually { await c.readySources.count == 1 })
        #expect(await c.offer(scope: f.scope(f.mic),samples: [Float](repeating: 0,count: 100)) == .scheduled)
        #expect(await captureEventually { await t.requests.count == 1 })
        await t.emit(f.event(f.mic,1,.progress(.init(capturedSampleEnd: 100,admittedSampleEnd: 100,consumedSampleEnd: 100,queuedSamples: 0,inFlightSamples: 0,heldSamples: 0,creditSamples: 49920))))
        let id = LiveSegmentID(epochID: f.mic.id,index: 0)
        let first = CommittedLiveSegment(id: id,source: .microphone,range: .init(samples: .init(start: 0,end: 50),meeting: nil),text: "Accepted prefix")
        await t.emit(f.event(f.mic,2,.committed(first)))
        #expect(await captureEventually { await store.projection().segments == [first] })
        await t.emit(f.event(f.mic,3,.committed(.init(id: id,source: .microphone,range: .init(samples: .init(start: 50,end: 100),meeting: nil),text: "Conflicting ID"))))
        #expect(await captureEventually { await gate.blocked })
        // The store is awaiting the bad write while capture continues. Neither
        // the unaccepted settlement nor the queued 100..<200 capture is durable.
        #expect(await c.offer(scope: f.scope(f.mic),samples: [Float](repeating: 0,count: 100)) == .scheduled)
        await gate.release(); try await c.waitUntilClosed()
        let display = await store.projection()
        #expect(display.isClosed && display.segments == [first])
        #expect(display.lanes.first?.progress.capturedSampleEnd == 200)
        #expect(display.coverage.contains { $0.kind == .gap(.unavailable) && $0.range.samples == .init(start: 50,end: 200) })
    }

    @Test func allLaneReadinessConfirmsResidencyAndClosureDoesNotWaitOnTeardown() async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture()
        let profile = LiveResourceProfile(id: "fixture",hardware: "fixture",modelRevision: "fixture",chunkMs: 1120,sourceCount: 2,
            qualificationID: "model-free-test-only",asrBytes: 400,attributionBytes: nil,headroomBytes: 100,concurrentChatModels: ["chat":300],backgroundWorkQualified: false)
        let resources = LiveModelResourcePolicy(profiles: [profile]), measurement = LiveResourceMeasurement(availableBytes: 1000,pressure: .normal)
        let lease = try await resources.admit(identity: f.identity,request: .init(profileID: "fixture",hardware: "fixture",modelRevision: "fixture",chunkMs: 1120,sourceCount: 2,attributionRequested: false),measurement: measurement)
        let store = LiveTranscriptStore(identity: f.identity)
        let c = LiveCaptureSessionCoordinator(input: f.input(both: true),store: store,transport: await t.transport(),resources: resources,lease: lease)
        await t.holdTeardown(); try await c.start()
        #expect(await captureEventually { await t.starts == 1 })
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        #expect(await captureEventually { await c.readySources.count == 1 })
        #expect(await resources.decide(.localChat(model: "chat"),measurement: measurement) == .deferred)
        await t.emit(f.event(f.system,0,.ready(generation: UUID(),originSample: 0)))
        #expect(await captureEventually { await resources.decide(.localChat(model: "chat"),measurement: measurement) == .admitted })
        let job = try #require(await resources.reserveJob(owner: UUID(),job: .localChat(model: "chat"),measurement: measurement))
        await c.retire(); try await c.waitUntilClosed()
        #expect(await store.projection().isClosed)
        #expect(await resources.reservedBytes == 400)
        await t.release()
        #expect(await captureEventually { await resources.reservedBytes == 0 })
        // Live teardown does not consume the independently owned answer permit.
        #expect(await resources.reserveJob(owner: job.owner,job: job.job,measurement: measurement) == job)
        await resources.releaseJob(job)
    }

    @Test func replacementRetriesNativeRetirementAndKeepsTheOtherSourceAndOldEvidence() async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture()
        let (c,store) = await f.coordinator(t,both: true)
        try await c.start()
        #expect(await captureEventually { await t.starts == 1 })
        for epoch in [f.mic,f.system] { await t.emit(f.event(epoch,0,.ready(generation: UUID(),originSample: 0))) }
        #expect(await captureEventually { await c.readySources.count == 2 })
        for epoch in [f.mic,f.system] { #expect(await c.offer(scope: f.scope(epoch),samples: [0]) == .scheduled) }
        await c.recordDiscontinuity(scope: f.scope(f.mic),reason: .deviceInterruption)
        #expect(await captureEventually { await t.requests.contains { if case .cut = $0 { return true }; return false } })
        let new = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        await t.rejectReplacements(true)
        #expect(try await c.replaceEpoch(scope: f.scope(f.mic),epoch: new) == false)
        await c.synchronizeStore()
        #expect(await store.projection().lanes.contains { $0.epoch.id == f.mic.id })
        await t.rejectReplacements(false)
        #expect(await captureEventually { (try? await c.replaceEpoch(scope: f.scope(f.mic),epoch: new)) == true })
        #expect(await captureEventually { await c.readySources.count == 2 })
        #expect(await c.offer(scope: f.scope(f.mic),samples: [0]) == .rejected)
        #expect(await c.offer(scope: f.scope(new),samples: [0]) == .scheduled)
        #expect(await captureEventually { await t.requests.contains { if case .packet(let p) = $0 { return p.scope.epochID == new.id }; return false } })
        func progress() -> LiveLaneEvent.Payload { .progress(.init(capturedSampleEnd: 1,admittedSampleEnd: 1,consumedSampleEnd: 1,queuedSamples: 0,inFlightSamples: 0,heldSamples: 0,creditSamples: 49920)) }
        let remote = CommittedLiveSegment(id: .init(epochID: f.system.id,index: 0),source: .system,
            range: .init(samples: .init(start: 0,end: 1),meeting: nil),text: "Other lane survives")
        let microphone = CommittedLiveSegment(id: .init(epochID: new.id,index: 0),source: .microphone,
            range: .init(samples: .init(start: 0,end: 1),meeting: nil),text: "Fresh mic epoch")
        await t.emit(f.event(f.mic,1,.committed(.init(id: .init(epochID: f.mic.id,index: 0),source: .microphone,range: remote.range,text: "Retired decoder"))))
        await t.emit(f.event(f.system,1,progress())); await t.emit(f.event(f.system,2,.committed(remote)))
        await t.emit(f.event(new,2,progress())); await t.emit(f.event(new,3,.committed(microphone)))
        #expect(await captureEventually { await store.projection().segments.count == 2 })
        let display = await store.projection()
        #expect(Set(display.segments.map(\.id)) == Set([microphone.id,remote.id]))
        #expect(display.coverage.contains { $0.epochID == f.mic.id && $0.kind == .gap(.deviceInterruption) })
        await c.retire(); try await c.waitUntilClosed()
    }

    @Test func closedLaneZeroCreditTelemetryDoesNotDiscardTheOtherLanesTail() async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture()
        let (c,store) = await f.coordinator(t,both: true)
        try await c.start()
        #expect(await captureEventually { await t.starts == 1 })
        for epoch in [f.mic,f.system] { await t.emit(f.event(epoch,0,.ready(generation: UUID(),originSample: 0))) }
        #expect(await captureEventually { await c.readySources.count == 2 })
        for epoch in [f.mic,f.system] { #expect(await c.offer(scope: f.scope(epoch),samples: [0]) == .scheduled) }
        await c.beginClosing(); await c.hardwareDidClose()
        #expect(await captureEventually { await t.requests.filter { if case .barrier = $0 { return true }; return false }.count == 2 })
        func progress(_ credit: Int64) -> LiveLaneEvent.Payload { .progress(.init(capturedSampleEnd: 1,admittedSampleEnd: 1,consumedSampleEnd: 1,queuedSamples: 0,inFlightSamples: 0,heldSamples: 0,creditSamples: credit)) }
        await t.emit(f.event(f.mic,1,progress(Int64(1120*16+32000))))
        await t.emit(f.event(f.mic,2,.settled(.init(epochID: f.mic.id,source: .microphone,range: .init(samples: .init(start: 0,end: 1),meeting: nil),kind: .processedSilence))))
        await t.emit(f.event(f.mic,3,.closed(sampleEnd: 1)))
        // This is the real helper's pumpDone telemetry, after closed and before
        // the other decoder's finish returns. It grants no new input credit.
        await t.emit(f.event(f.mic,4,progress(0)))
        await t.emit(f.event(f.system,1,progress(Int64(1120*16+32000))))
        let remote = CommittedLiveSegment(id: .init(epochID: f.system.id,index: 0),source: .system,
            range: .init(samples: .init(start: 0,end: 1),meeting: nil),text: "Remote closing tail")
        await t.emit(f.event(f.system,2,.committed(remote)))
        await t.emit(f.event(f.system,3,.closed(sampleEnd: 1)))
        await t.emit(.finished(f.identity))
        try await c.waitUntilClosed()
        #expect(await store.projection().segments == [remote])
        #expect(await store.projection().coverage.contains { $0.source == .microphone && $0.kind == .processedSilence })
    }

    @Test func stopDoesNotJoinCancellationIgnoringPreparationOrAttachItsLateCompletion() async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture()
        await t.configure(begin: true)
        let (c,store) = await f.coordinator(t)
        try await c.start()
        #expect(await captureEventually { await t.starts == 1 })
        #expect(await c.offer(scope: f.scope(f.mic),samples: [Float](repeating: 0,count: 3200)) == .dropped)
        await c.beginClosing(); await c.hardwareDidClose()
        try await c.waitUntilClosed()
        let before = await store.snapshot()
        #expect(await store.projection().isClosed)
        #expect(before.lanes.first?.settledSampleEnd == 3200)
        #expect(await store.projection().coverage.contains { $0.kind == .gap(.preparation) })
        await t.release()
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        try await Task.sleep(for: .milliseconds(10))
        #expect(await store.snapshot() == before)
        #expect(await t.shutdowns >= 1)
    }

    @Test(arguments: [560,1120,2240]) func creditsIncludeBlockedAppCommandsAndWholeProvisionalCuts(_ tier: Int) async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture()
        await t.configure(command: true)
        let (c,store) = await f.coordinator(t,tier: tier)
        try await c.start()
        #expect(await captureEventually { await t.starts == 1 })
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        #expect(await captureEventually { await c.readySources.contains(.microphone) })
        let limit = tier * 16 + 32000
        var remaining = limit
        while remaining > 0 {
            let count = min(3200,remaining)
            #expect(await c.offer(scope: f.scope(f.mic),samples: [Float](repeating: 0,count: count)) == .scheduled)
            remaining -= count
        }
        #expect(await c.offer(scope: f.scope(f.mic),samples: [0]) == .dropped)
        // No consumption receipt: the blocked packet, unsent queue and native
        // held input cannot be counted as free credit or committed evidence.
        await c.synchronizeStore()
        let snapshot = await store.snapshot()
        #expect(snapshot.lanes.first?.settledSampleEnd == Int64(limit+1))
        #expect(snapshot.lanes.first?.progress.admittedSampleEnd == 0)
        #expect(snapshot.segments.isEmpty)
        #expect(await store.projection().coverage.contains { $0.kind == .gap(.overload) && $0.range.samples == .init(start: 0,end: Int64(limit+1)) })
        await c.retire(); try await c.waitUntilClosed(); await t.release()
        #expect(await t.requests.count <= 2)
    }

    @Test func registeredClosingTailCommitsButLatePartialAndNewInputAreRejected() async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture()
        let (c,store) = await f.coordinator(t)
        try await c.start()
        #expect(await captureEventually { await t.starts == 1 })
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        #expect(await captureEventually { await c.readySources.contains(.microphone) })
        #expect(await c.offer(scope: f.scope(f.mic),samples: [0,0]) == .scheduled)
        await c.beginClosing()
        #expect(await c.offer(scope: f.scope(f.mic),samples: [0]) == .rejected)
        #expect(await c.offer(scope: f.scope(f.mic),samples: [0],closingTail: true) == .scheduled)
        #expect(await captureEventually { await t.requests.count == 2 })
        await c.hardwareDidClose()
        #expect(await c.offer(scope: f.scope(f.mic),samples: [0],closingTail: true) == .rejected)
        #expect(await captureEventually { await t.requests.contains { if case .barrier(let b) = $0 { return b.sampleEnd == 3 && b.nextPacketSequence == 2 && b.kind == .finish }; return false } })
        await t.emit(f.event(f.mic,1,.progress(.init(capturedSampleEnd: 3,admittedSampleEnd: 3,consumedSampleEnd: 3,queuedSamples: 0,inFlightSamples: 0,heldSamples: 0,creditSamples: Int64(1120*16+32000)))))
        await t.emit(f.event(f.mic,2,.partial(.init(epochID: f.mic.id,source: .microphone,revision: 0,samples: .init(start: 0,end: 3),text: "Retired preview"))))
        let segment = CommittedLiveSegment(id: .init(epochID: f.mic.id,index: 0),source: .microphone,range: .init(samples: .init(start: 0,end: 3),meeting: nil),text: "Closing evidence")
        await t.emit(f.event(f.mic,3,.committed(segment)))
        await t.emit(f.event(f.mic,4,.closed(sampleEnd: 3)))
        await t.emit(.finished(f.identity))
        try await c.waitUntilClosed()
        let display = await store.projection()
        #expect(display.isClosed && display.partials.isEmpty && display.segments == [segment])
        #expect(await store.snapshot(selection: .evidence([segment.id],includeUnaligned: true)).segments == [segment])
    }

    @Test func ownDrainDeadlineSettlesRemainderWithoutWaitingOnBlockedTransport() async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture()
        await t.configure(command: true)
        let (c,store) = await f.coordinator(t)
        try await c.start()
        #expect(await captureEventually { await t.starts == 1 })
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        #expect(await captureEventually { await c.readySources.contains(.microphone) })
        #expect(await c.offer(scope: f.scope(f.mic),samples: [0,0,0]) == .scheduled)
        await c.beginClosing(); await c.hardwareDidClose()
        let clock = ContinuousClock(), start = clock.now
        try await c.waitUntilClosed()
        #expect(start.duration(to: clock.now) < .milliseconds(500))
        #expect(await store.projection().isClosed)
        #expect(await store.projection().coverage.contains { $0.kind == .gap(.deadline) && $0.range.samples?.end == 3 })
        await t.release()
    }

    @Test func foreignAndMalformedProgressCannotMintCreditsOrAlterEvidence() async throws {
        let f = CaptureCoordinatorFixture(), t = CaptureTransportFixture()
        let (c,store) = await f.coordinator(t)
        try await c.start()
        #expect(await captureEventually { await t.starts == 1 })
        let foreign = LiveLaneScope(identity: .init(recordingID: UUID(),captureSessionID: UUID()),source: .microphone,epochID: f.mic.id)
        await t.emit(.lane(.init(scope: foreign,sequence: 0,payload: .ready(generation: UUID(),originSample: 0))))
        #expect(await c.offer(scope: foreign,samples: [0]) == .rejected)
        await t.emit(f.event(f.mic,0,.ready(generation: UUID(),originSample: 0)))
        #expect(await captureEventually { await c.readySources.contains(.microphone) })
        #expect(await c.offer(scope: f.scope(f.mic),samples: [0]) == .scheduled)
        await t.emit(f.event(f.mic,1,.progress(.init(capturedSampleEnd: 1,admittedSampleEnd: 1,consumedSampleEnd: 2,queuedSamples: 0,inFlightSamples: 0,heldSamples: 0,creditSamples: 999999))))
        #expect(await captureEventually { await store.projection().isClosed })
        #expect(await store.snapshot().segments.isEmpty)
        #expect(await store.snapshot().lanes.first?.progress.consumedSampleEnd == 0)
    }
}
