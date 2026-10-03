import AVFoundation
import Foundation
import Testing
import dBriefWire
@testable import dBrief

private actor StartPreparationGate {
    enum Point: String, Sendable { case none, context, cache, memory, receipt, handoffMemory }
    let point: Point
    private(set) var entered = false
    private(set) var returned = false
    private(set) var inspected: [LiveSessionBegin] = []
    private(set) var samples = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var pressure = LiveResourceMeasurement.Pressure.normal
    init(_ point: Point = .none) { self.point = point }
    func hold(_ current: Point) async {
        guard current == point, !released else { return }
        entered = true
        await withCheckedContinuation { waiter = $0 }
        returned = true
    }
    func inspect(_ input: LiveSessionBegin) async { inspected.append(input); await hold(.cache) }
    func memory() async -> LiveResourceMeasurement {
        samples += 1
        let sample = LiveResourceMeasurement(availableBytes: 2000,pressure: pressure)
        if samples == 1 { await hold(.memory) }
        if samples == 3 { await hold(.handoffMemory) }
        return sample
    }
    func critical() { pressure = .critical }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private struct StartPreparationFixture {
    let folder: URL
    let input: LiveSessionBegin
    let ingress: LiveCaptureIngress
    let policy: LiveModelResourcePolicy
    let receiptStore: PrivacyReceiptStore
    let scope: RecordingPrivacyScope
    let runID = UUID()
    let request = LiveResourceRequest(profileID: "prepared",hardware: "fixture-mac",modelRevision: "fixture-asr",
        chunkMs: 1120,sourceCount: 2,attributionRequested: false)
    init(policy shared: LiveModelResourcePolicy? = nil) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-preparation-\(UUID())")
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
        input = .init(identity: identity,configuration: .init(language: .auto,chunkMs: 1120,modelDirectory: "/fixture/frozen-cache"),
            epochs: [LiveSource.microphone,.system].map {
                .init(id: UUID(),source: $0,engineRevision: "fixture-asr",language: "auto",meetingOriginNanoseconds: nil)
            })
        ingress = LiveCaptureIngress(input: input)
        policy = shared ?? LiveModelResourcePolicy(profiles: [.init(id: "prepared",hardware: "fixture-mac",modelRevision: "fixture-asr",
            chunkMs: 1120,sourceCount: 2,qualificationID: "test-only",asrBytes: 500,attributionBytes: nil,headroomBytes: 100,
            concurrentChatModels: ["chat":600],backgroundWorkQualified: false)])
        receiptStore = PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps"))
        scope = .init(recordingID: identity.recordingID,store: receiptStore,pendingRootURL: folder.appendingPathComponent("pending"))
    }
    func remove() { try? FileManager.default.removeItem(at: folder) }
    func preparation(_ gate: StartPreparationGate = StartPreparationGate(), request override: LiveResourceRequest? = nil,
                     scope foreignScope: RecordingPrivacyScope? = nil, foreignContext: Bool = false,
                     cacheFailure: Bool = false, ingress overrideIngress: LiveCaptureIngress? = nil) -> LiveCaptureStartPreparation {
        LiveCaptureStartPreparation(input: input,ingress: overrideIngress ?? ingress,resources: policy,privacyScope: foreignScope ?? scope,
            runID: runID,request: override ?? request,cacheCheck: { input in
                await gate.inspect(input)
                if cacheFailure { throw LiveProtocolError.unavailable }
            },currentMemory: { await gate.memory() },context: { scope, runID in
                let context = await scope.context(runID: runID)
                await gate.hold(.context)
                if foreignContext { return .init(receiptURL: context.receiptURL,store: context.store,runID: UUID(),recordingID: context.recordingID) }
                return context
            },beginReceipt: { operation, context in
                let token = await PrivacyTrace.begin(operation,in: context)
                await gate.hold(.receipt)
                return token
            })
    }
    func buffer(_ source: LiveSource, rawEpoch: UUID) throws -> LiveAudioBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000,channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 16)); pcm.frameLength = 16
        let metadata = LiveAudioMetadata(sourceEpoch: rawEpoch,role: source == .microphone ? .mic : .system,timestamp: .unavailable,
            emittedFrames: .init(startFrame: 32,frameCount: 16,sampleRate: 16000),writeOutcome: .failed,converter: nil)
        let ticket = try #require(ingress.reserveRaw(source: source,metadata: metadata,frames: 16,rate: 16000,bytes: 64,format: format))
        return .init(pcm,metadata: metadata,ingress: ticket)
    }
    func outcome(at url: URL? = nil) async -> PrivacyAttempt.Outcome? {
        try? await receiptStore.load(from: url ?? scope.pendingReceiptURL)?.attempts.first?.outcome
    }
}

private actor PreparedStartNative {
    let events: AsyncThrowingStream<LiveSessionEvent, Error>
    let output: AsyncThrowingStream<LiveSessionEvent, Error>.Continuation
    private(set) var inputs: [LiveSessionBegin] = []
    private(set) var requests: [LiveSessionRequest] = []
    private(set) var shutdowns = 0
    private(set) var shutdownReturned = false
    private var holdShutdown = false
    private var waiter: CheckedContinuation<Void, Never>?
    init() { (events,output) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(32)) }
    nonisolated var transport: LiveASRTransport {
        .init(begin: { await self.begin($0) },command: { await self.command($0) },deadline: { _ in },shutdown: { await self.shutdown() })
    }
    func begin(_ input: LiveSessionBegin) -> AsyncThrowingStream<LiveSessionEvent, Error> {
        inputs.append(input)
        for epoch in input.epochs { output.yield(.lane(.init(scope: .init(identity: input.identity,source: epoch.source,epochID: epoch.id),
            sequence: 0,payload: .ready(generation: UUID(),originSample: 0)))) }
        return events
    }
    func command(_ request: LiveSessionRequest) -> LiveSessionReply { requests.append(request); return .accepted }
    func emit(_ event: LiveSessionEvent) { output.yield(event) }
    func holdTeardown() { holdShutdown = true }
    func release() { holdShutdown = false; waiter?.resume(); waiter = nil }
    private func shutdown() async {
        shutdowns += 1
        if holdShutdown { await withCheckedContinuation { waiter = $0 } }
        shutdownReturned = true; output.finish()
    }
    var finishCount: Int { requests.filter { if case .barrier(let b) = $0 { b.kind == .finish } else { false } }.count }
}

private actor PreparedStartDeadline {
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?
    func sleep(_ duration: Duration) async {
        guard !fired else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func fire() { fired = true; waiter?.resume(); waiter = nil }
}

private func preparationEventually(_ predicate: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: TestTiming.asyncDeadline)
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await predicate()
}

@Suite struct LiveCaptureStartPreparationTests {
    @Test func unqualifiedProfileCannotInspectCacheBeforeRejection() async throws {
        let f = try StartPreparationFixture(), gate = StartPreparationGate()
        defer { f.remove() }
        let request = LiveResourceRequest(profileID: "not-qualified",hardware: "fixture-mac",modelRevision: "fixture-asr",
            chunkMs: 1120,sourceCount: 2,attributionRequested: false)
        let preparation = f.preparation(gate,request: request)
        await #expect(throws: LiveResourceRejection.unsupported) { _ = try await preparation.prepare() }
        #expect(await gate.inspected.isEmpty)
        #expect(await gate.samples == 0)
        #expect(await f.policy.reservedBytes == 0)
        #expect(await f.outcome() == nil)
    }

    @Test func preparedReceiptUsesFrozenInputScopeAndRunAndCannotBePreparedTwice() async throws {
        let f = try StartPreparationFixture(), gate = StartPreparationGate(), preparation = f.preparation(gate)
        defer { f.remove() }
        let result = try await preparation.prepare()
        #expect(result.input == f.input && result.lease.identity == f.input.identity)
        #expect(await gate.inspected == [f.input])
        let receipt = try #require(try await f.receiptStore.load(from: f.scope.pendingReceiptURL))
        #expect(receipt.attempts.count == 1 && receipt.attempts[0].runID == f.runID)
        #expect(receipt.attempts[0].operation == .init(stage: .liveTranscription,data: [.recordingAudio,.metadata],destination: .local(provider: .fluidAudio)))
        await #expect(throws: LiveProtocolError.invalidConfiguration) { try await preparation.prepare() }
        #expect(await f.outcome() == .started)
        await preparation.complete(.cancelled)?.value
        #expect(await preparationEventually { await f.policy.reservedBytes == 0 })
        #expect(await preparationEventually { await f.outcome() == .cancelled })
    }

    @Test(arguments: ["scope","sourceCount","revision","attribution","chunk","vad"])
    func invalidFrozenConfigurationFailsBeforeCacheAdmissionOrPrivacyAttempt(kind: String) async throws {
        let f = try StartPreparationFixture(), gate = StartPreparationGate()
        defer { f.remove() }
        let vad = LiveVADConfiguration(identity: .init(modelRevision: "fixture-vad",modelFingerprint: String(repeating: "a",count: 64),
            runtimeRevision: "21493f8dac5a97e65742e6ff26f42f164c2fda0f"),modelPath: "/fixture/vad.mlmodelc")
        let request = LiveResourceRequest(profileID: "prepared",hardware: "fixture-mac",modelRevision: kind == "revision" ? "foreign" : "fixture-asr",
            chunkMs: kind == "chunk" ? 560 : 1120,sourceCount: kind == "sourceCount" ? 1 : 2,
            attributionRequested: kind == "attribution",vad: kind == "vad" ? vad : nil)
        let foreign = RecordingPrivacyScope(recordingID: UUID(),store: f.receiptStore,pendingRootURL: f.folder.appendingPathComponent("foreign"))
        let preparation = f.preparation(gate,request: request,scope: kind == "scope" ? foreign : nil)
        await #expect(throws: LiveProtocolError.invalidConfiguration) { try await preparation.prepare() }
        #expect(await gate.inspected.isEmpty)
        #expect(await f.policy.reservedBytes == 0)
        #expect(await f.outcome() == nil)
    }

    @Test func returnedContextCannotSubstituteTheFrozenPrivacyRun() async throws {
        let f = try StartPreparationFixture(), gate = StartPreparationGate()
        defer { f.remove() }
        let preparation = f.preparation(gate,foreignContext: true)
        await #expect(throws: LiveProtocolError.invalidConfiguration) { try await preparation.prepare() }
        #expect(await gate.inspected.isEmpty)
        #expect(await f.policy.reservedBytes == 0)
        #expect(await f.outcome() == nil)
    }

    @Test(arguments: [StartPreparationGate.Point.context,.cache,.memory,.receipt])
    fileprivate func cancellationAtHeldPreparationBoundariesReleasesOnlyItsNewReceipt(point: StartPreparationGate.Point) async throws {
        let f = try StartPreparationFixture(), gate = StartPreparationGate(point), preparation = f.preparation(gate)
        defer { f.remove() }
        let task = Task { try await preparation.prepare() }
        #expect(await preparationEventually { await gate.entered })
        task.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await gate.returned)
        #expect(await f.policy.reservedBytes == 0)
        if point == .receipt { #expect(await preparationEventually { await f.outcome() == .cancelled }) }
        else { #expect(await f.outcome() == nil) }
    }

    @Test func cacheFailureNeverReservesOrCreatesAnExecutionAttempt() async throws {
        let f = try StartPreparationFixture(), preparation = f.preparation(cacheFailure: true)
        defer { f.remove() }
        await #expect(throws: LiveProtocolError.unavailable) { try await preparation.prepare() }
        #expect(await f.policy.reservedBytes == 0)
        #expect(await f.outcome() == nil)
    }
}

@Suite struct LivePreparedStartIntegrationTests {
    @Test(arguments: [StartPreparationGate.Point.context,.cache,.receipt])
    fileprivate func realRegisteredEOFDuringHeldPreparationClosesWithoutWaitingForEitherDeadline(point: StartPreparationGate.Point) async throws {
        let f = try StartPreparationFixture(), gate = StartPreparationGate(point), native = PreparedStartNative()
        let preparation = f.preparation(gate), store = LiveTranscriptStore(identity: f.input.identity)
        let core = LiveCaptureSessionCoordinator(input: f.input,store: store,transport: native.transport,
            drainDeadline: .seconds(300),preparationDeadline: .seconds(300),resources: f.policy,ingress: f.ingress,preparation: preparation)
        let actual = try LiveCaptureStreamSession(input: f.input,ingress: f.ingress,coordinator: core)
        let (mic,micOutput) = AsyncStream<LiveAudioBuffer>.makeStream(), (system,systemOutput) = AsyncStream<LiveAudioBuffer>.makeStream()
        let micEpoch = UUID(), systemEpoch = UUID()
        var micBuffer: LiveAudioBuffer? = try f.buffer(.microphone,rawEpoch: micEpoch)
        var systemBuffer: LiveAudioBuffer? = try f.buffer(.system,rawEpoch: systemEpoch)
        defer { actual.expire(); f.remove() }
        #expect(actual.register(.init(mic: mic,system: system,language: "auto")))
        #expect(await preparationEventually { await gate.entered })
        if let micBuffer { micOutput.yield(micBuffer) }
        if let systemBuffer { systemOutput.yield(systemBuffer) }
        #expect(await preparationEventually { (await store.projection()).captureLosses.count == 2 })
        actual.beginClosing(); micOutput.finish(); systemOutput.finish()
        let close = Task { try await actual.hardwareDidClose() }
        #expect(await preparationEventually { (await store.projection()).isClosed })
        #expect(await native.inputs.isEmpty)
        #expect(await gate.entered)
        #expect(await gate.returned == false)
        #expect(await preparationEventually { await f.policy.reservedBytes == 0 })
        // Release only after asserting EOF/store/credit closure. The five-minute
        // fixture timers cannot expire within the three bounded observations above.
        await gate.release(); _ = await close.result
        #expect(await preparationEventually { await gate.returned })
        let losses = (await store.projection()).captureLosses
        #expect(losses.contains { $0.source == .microphone && $0.sourceEpoch == micEpoch && $0.frames?.startFrame == 32 && $0.frames?.frameCount == 16 })
        #expect(losses.contains { $0.source == .system && $0.sourceEpoch == systemEpoch && $0.frames?.startFrame == 32 && $0.frames?.frameCount == 16 })
        #expect(f.ingress.statistics(.microphone).rawBytes == 64 && f.ingress.statistics(.system).rawBytes == 64)
        micBuffer = nil; systemBuffer = nil
        #expect(await preparationEventually { f.ingress.statistics(.microphone).rawBytes == 0 && f.ingress.statistics(.system).rawBytes == 0 })
        if point == .receipt { #expect(await preparationEventually { await f.outcome() == .cancelled }) }
    }

    @Test func lateOldPrivacyWriteFollowsItsBindingAndCannotReleaseTheNewRecordingLease() async throws {
        let old = try StartPreparationFixture(), gate = StartPreparationGate(.receipt), native = PreparedStartNative()
        let preparation = old.preparation(gate), store = LiveTranscriptStore(identity: old.input.identity)
        let core = LiveCaptureSessionCoordinator(input: old.input,store: store,transport: native.transport,
            resources: old.policy,ingress: old.ingress,preparation: preparation)
        defer { old.remove() }
        try await core.start()
        #expect(await preparationEventually { await gate.entered })
        let audio = old.folder.appendingPathComponent("final.m4a"), sidecar = PrivacyReceiptStore.sidecarURL(for: audio)
        await old.scope.bind(to: audio)
        await core.beginClosing(); await core.hardwareDidClose()
        #expect(await preparationEventually { (await store.projection()).isClosed })
        #expect(await preparationEventually { await old.policy.reservedBytes == 0 })
        var fresh: StartPreparationFixture?
        var newPreparation: LiveCaptureStartPreparation?
        defer { fresh?.remove() }
        do {
            let next = try StartPreparationFixture(policy: old.policy)
            fresh = next
            let preparing = next.preparation(); newPreparation = preparing
            let newReceipt = try await preparing.prepare()
            await gate.release()
            #expect(await preparationEventually { await old.outcome(at: sidecar) == .cancelled })
            #expect(await old.policy.validateActiveLease(newReceipt.lease))
            #expect(await next.outcome() == .started)
            #expect(await native.inputs.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: old.scope.pendingReceiptURL.path))
            await preparing.complete(.cancelled)?.value
        }
        catch {
            await newPreparation?.complete(.cancelled)?.value
            await gate.release(); await core.retire()
            #expect(await preparationEventually { await gate.returned })
            throw error
        }
    }

    @Test func pressureAfterReceiptWritePreventsNativeAndMarksTheOriginalAttemptFailed() async throws {
        let f = try StartPreparationFixture(), gate = StartPreparationGate(.receipt), native = PreparedStartNative()
        let store = LiveTranscriptStore(identity: f.input.identity)
        let core = LiveCaptureSessionCoordinator(input: f.input,store: store,transport: native.transport,
            resources: f.policy,ingress: f.ingress,preparation: f.preparation(gate))
        defer { f.remove() }
        try await core.start()
        #expect(await preparationEventually { await gate.entered })
        await gate.critical(); await gate.release()
        #expect(await preparationEventually { (await store.projection()).isClosed })
        #expect(await preparationEventually { await f.policy.reservedBytes == 0 })
        #expect(await preparationEventually { await f.outcome() == .failed })
        #expect(await native.inputs.isEmpty)
    }

    @Test func synchronousIngressCloseDuringTheFinalMemorySampleWinsDispatch() async throws {
        let f = try StartPreparationFixture(), gate = StartPreparationGate(.handoffMemory), native = PreparedStartNative()
        let store = LiveTranscriptStore(identity: f.input.identity)
        let core = LiveCaptureSessionCoordinator(input: f.input,store: store,transport: native.transport,
            resources: f.policy,ingress: f.ingress,preparation: f.preparation(gate))
        defer { f.remove() }
        try await core.start()
        #expect(await preparationEventually { await gate.entered })
        // Simulate the adapter's synchronous seal before its detached core
        // beginClosing is delivered. The earlier open observation is stale.
        f.ingress.closeInput(); await gate.release()
        #expect(await preparationEventually { await f.policy.reservedBytes == 0 })
        await core.beginClosing(); await core.hardwareDidClose()
        #expect(await preparationEventually { (await store.projection()).isClosed })
        #expect(await native.inputs.isEmpty)
        #expect(await preparationEventually { await f.outcome() == .cancelled })
    }

    @Test(arguments: [false,true])
    func onlyValidatedHelperFinishSucceedsAndAcceptedLeaseWaitsForActualShutdown(abandoned: Bool) async throws {
        let f = try StartPreparationFixture(), native = PreparedStartNative(), store = LiveTranscriptStore(identity: f.input.identity)
        let core = LiveCaptureSessionCoordinator(input: f.input,store: store,transport: native.transport,
            resources: f.policy,ingress: f.ingress,preparation: f.preparation())
        defer { f.remove() }
        await native.holdTeardown()
        try await core.start()
        #expect(await preparationEventually { await core.readySources.count == 2 })
        #expect(await native.inputs == [f.input])
        if abandoned { await core.abandonCurrentSource(.microphone) }
        await core.beginClosing(); await core.hardwareDidClose()
        #expect(await preparationEventually { await native.finishCount == (abandoned ? 1 : 2) })
        for epoch in f.input.epochs where !abandoned || epoch.source != .microphone {
            await native.emit(.lane(.init(scope: .init(identity: f.input.identity,source: epoch.source,epochID: epoch.id),
                sequence: 1,payload: .closed(sampleEnd: 0))))
        }
        if !abandoned { await native.emit(.finished(f.input.identity)) }
        #expect(await preparationEventually { (await store.projection()).isClosed })
        #expect(await f.policy.reservedBytes == 500)
        #expect(await preparationEventually { await f.outcome() == (abandoned ? .failed : .succeeded) })
        await native.release()
        #expect(await preparationEventually { await native.shutdownReturned })
        #expect(await preparationEventually { await f.policy.reservedBytes == 0 })
    }

    @Test func duplicateCoreCannotCompleteOrReleaseTheOriginalPreparationOwner() async throws {
        let f = try StartPreparationFixture(), gate = StartPreparationGate(.receipt), preparation = f.preparation(gate)
        let native = PreparedStartNative(), store = LiveTranscriptStore(identity: f.input.identity)
        let first = LiveCaptureSessionCoordinator(input: f.input,store: store,transport: native.transport,
            resources: f.policy,ingress: f.ingress,preparation: preparation)
        let duplicate = LiveCaptureSessionCoordinator(input: f.input,store: store,transport: PreparedStartNative().transport,
            resources: f.policy,ingress: f.ingress,preparation: preparation)
        defer { f.remove() }
        try await first.start()
        #expect(await preparationEventually { await gate.entered })
        await #expect(throws: LiveProtocolError.invalidConfiguration) { try await duplicate.start() }
        await duplicate.retire()
        #expect(await f.outcome() == .started)
        #expect(await f.policy.reservedBytes == 500)
        #expect(f.ingress.nativeStartAvailable)
        #expect((await store.projection()).isClosed == false)
        await first.beginClosing(); await first.hardwareDidClose(); await gate.release()
        #expect(await preparationEventually { await f.outcome() == .cancelled })
        #expect(await preparationEventually { await f.policy.reservedBytes == 0 })
    }

    @Test(arguments: ["samePreparation","differentPreparation","differentIngress"])
    func rejectedDuplicateCannotClearOriginalPartialsOrReturnAnotherNativeOwnersCredit(duplicateKind: String) async throws {
        let f = try StartPreparationFixture(), preparation = f.preparation(), native = PreparedStartNative(), unrelated = PreparedStartNative()
        let store = LiveTranscriptStore(identity: f.input.identity)
        let first = LiveCaptureSessionCoordinator(input: f.input,store: store,transport: native.transport,
            resources: f.policy,ingress: f.ingress,preparation: preparation)
        let otherIngress = duplicateKind == "differentIngress" ? LiveCaptureIngress(input: f.input) : f.ingress
        let duplicate = LiveCaptureSessionCoordinator(input: f.input,store: store,transport: unrelated.transport,
            resources: f.policy,ingress: otherIngress,
            preparation: duplicateKind == "samePreparation" ? preparation : f.preparation(ingress: otherIngress))
        defer { f.remove() }
        try await first.start()
        #expect(await preparationEventually { await first.readySources.count == 2 })
        let epoch = f.input.epochs[0], scope = LiveLaneScope(identity: f.input.identity,source: epoch.source,epochID: epoch.id)
        let raw = try f.buffer(.microphone,rawEpoch: UUID()), ticket = try #require(raw.ingress)
        let normalized = try #require(f.ingress.normalize(ticket,scope: scope,emittedSamples: 16))
        #expect(await first.offer(scope: scope,samples: Array(repeating: 0.25,count: 16),reservation: normalized) == .scheduled)
        #expect(await preparationEventually { await native.requests.contains { if case .packet = $0 { true } else { false } } })
        await native.emit(.lane(.init(scope: scope,sequence: 1,payload: .admitted(packetSequence: 0,sampleEnd: 16))))
        await native.emit(.lane(.init(scope: scope,sequence: 2,payload: .partial(.init(epochID: epoch.id,source: epoch.source,
            revision: 1,samples: .init(start: 0,end: 16),text: "Original preview")))))
        #expect(await preparationEventually { (await store.projection()).partials.first?.text == "Original preview" })
        await #expect(throws: LiveProtocolError.invalidConfiguration) { try await duplicate.start() }
        await duplicate.beginClosing(); await duplicate.hardwareDidClose(); await duplicate.retire(); await duplicate.synchronizeStore()
        #expect((await store.projection()).partials.first?.text == "Original preview")
        #expect((await store.projection()).isClosed == false)
        #expect(f.ingress.statistics(.microphone).nativeSamples == 16)
        #expect(await f.policy.reservedBytes == 500)
        #expect(await unrelated.shutdowns == 0)
        await native.holdTeardown(); await first.retire()
        #expect(await preparationEventually { await native.shutdowns == 1 })
        #expect(f.ingress.statistics(.microphone).nativeSamples == 16)
        await native.release()
        #expect(await preparationEventually { await native.shutdownReturned })
        #expect(await preparationEventually { f.ingress.statistics(.microphone).nativeSamples == 0 })
        #expect(await preparationEventually { await f.policy.reservedBytes == 0 })
        withExtendedLifetime(raw) {}
    }

    @Test func deadlineOutcomeSurvivesCancellationAndLateOriginalPrivacyTokenArrival() async throws {
        let f = try StartPreparationFixture(), gate = StartPreparationGate(.receipt), native = PreparedStartNative()
        let store = LiveTranscriptStore(identity: f.input.identity), deadline = PreparedStartDeadline()
        let core = LiveCaptureSessionCoordinator(input: f.input,store: store,transport: native.transport,
            resources: f.policy,ingress: f.ingress,preparation: f.preparation(gate),deadlineSleep: { await deadline.sleep($0) })
        defer { f.remove() }
        do {
            try await core.start()
            #expect(await preparationEventually { await gate.entered })
            #expect(await f.outcome() == .started)
            #expect(await f.policy.reservedBytes == 500)
            await deadline.fire()
            #expect(await preparationEventually { (await store.projection()).isClosed })
            #expect(await gate.returned == false)
            #expect(await preparationEventually { await f.policy.reservedBytes == 0 })
            await gate.release()
            #expect(await preparationEventually { await gate.returned })
            #expect(await preparationEventually { await f.outcome() == .failed })
            #expect(await native.inputs.isEmpty)
        } catch {
            await deadline.fire(); await gate.release(); await core.retire()
            if await gate.entered { #expect(await preparationEventually { await gate.returned }) }
            throw error
        }
    }
}
