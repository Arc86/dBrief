import Foundation
import Testing
@testable import dBriefWire
@testable import dBrief

private actor ASRPreparedNative {
    let events: AsyncThrowingStream<LiveSessionEvent,Error>
    let output: AsyncThrowingStream<LiveSessionEvent,Error>.Continuation
    private(set) var inputs: [LiveSessionBegin] = []
    private(set) var shutdowns = 0
    private var waiter: CheckedContinuation<Void,Never>?
    private var held = false
    private var beginHeld = false
    private var beginWaiter: CheckedContinuation<Void,Never>?
    init() { (events,output) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(32)) }
    nonisolated var transport: LiveASRTransport {
        .init(begin: { await self.begin($0) },command: { _ in .accepted },deadline: { _ in },shutdown: { await self.shutdown() })
    }
    func begin(_ input: LiveSessionBegin) async -> AsyncThrowingStream<LiveSessionEvent,Error> {
        inputs.append(input)
        if beginHeld { await withCheckedContinuation { beginWaiter = $0 } }
        for epoch in input.epochs { output.yield(.lane(.init(scope: .init(identity: input.identity,source: epoch.source,epochID: epoch.id),
            sequence: 0,payload: .ready(generation: UUID(),originSample: 0)))) }
        return events
    }
    func fail() { if let input = inputs.first { output.yield(.failed(input.identity,.unavailable)) } }
    func holdShutdown() { held = true }
    func holdBegin() { beginHeld = true }
    func releaseBegin() { beginHeld = false; beginWaiter?.resume(); beginWaiter = nil }
    func release() { held = false; waiter?.resume(); waiter = nil }
    func shutdown() async {
        shutdowns += 1
        if held { await withCheckedContinuation { waiter = $0 } }
        output.finish()
    }
}
private actor ASRPreparedTimer {
    private var waiters: [CheckedContinuation<Void,Never>] = []
    private var released = false
    var pending: Int { waiters.count }
    func hold() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let original = waiters; waiters = []; for waiter in original { waiter.resume() } }
}
private final class ASRWeakCore: @unchecked Sendable {
    private let lock = NSLock(); private weak var core: LiveCaptureSessionCoordinator?
    init(_ value: LiveCaptureSessionCoordinator) { core = value }
    var alive: Bool { lock.withLock { core != nil } }
}

private struct ASRPreparedFixture {
    let files: ASRAssetsFixture
    let budget: LiveASRStagingBudget
    let assets: LiveASRModelAssets
    let input: LiveSessionBegin
    let ingress: LiveCaptureIngress
    let policy: LiveModelResourcePolicy
    let request: LiveResourceRequest
    let scope: RecordingPrivacyScope
    init(probe: LiveASRModelAssets.Probe? = nil, profileIdentity: LiveASRIdentity = ASRAssetsFixture.identity()) throws {
        files = try ASRAssetsFixture(); budget = LiveASRStagingBudget(); assets = try files.assets(budget: budget,probe: probe)
        let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
        input = .init(identity: identity,configuration: assets.configuration,epochs: [.init(id: UUID(),source: .microphone,
            engineRevision: "fixture-asr",language: "auto",meetingOriginNanoseconds: nil)])
        ingress = LiveCaptureIngress(input: input)
        policy = .init(profiles: [.init(id: "asr",hardware: "fixture",modelRevision: "fixture-asr",chunkMs: 1120,sourceCount: 1,
            qualificationID: "test-only",asrBytes: 500,attributionBytes: nil,headroomBytes: 100,concurrentChatModels: [:],
            backgroundWorkQualified: false,asr: profileIdentity)])
        request = .init(profileID: "asr",hardware: "fixture",modelRevision: "fixture-asr",chunkMs: 1120,sourceCount: 1,
            attributionRequested: false,asr: input.configuration.identity)
        scope = .init(recordingID: identity.recordingID,store: PrivacyReceiptStore(gapDirectoryURL: files.root.appendingPathComponent("gaps")),
                      pendingRootURL: files.root.appendingPathComponent("privacy"))
    }
    func preparation() -> LiveCaptureStartPreparation {
        .init(input: input,ingress: ingress,resources: policy,privacyScope: scope,runID: UUID(),request: request,
              cacheCheck: { _ in },currentMemory: { .init(availableBytes: 2000,pressure: .normal) },asrAssets: assets)
    }
}

@Suite struct LiveASRPreparedIntegrationTests {
    @Test func originalBeginMustReturnBeforeAnEarlyShutdownCanReleaseTheSnapshotOrLease() async throws {
        let f = try ASRPreparedFixture(); defer { f.files.remove() }
        let native = ASRPreparedNative(), timer = ASRPreparedTimer(), store = LiveTranscriptStore(identity: f.input.identity)
        await native.holdBegin()
        let core = LiveCaptureSessionCoordinator(input: f.input,store: store,transport: native.transport,
            resources: f.policy,ingress: f.ingress,preparation: f.preparation(),deadlineSleep: { _ in await timer.hold() })
        try await core.start()
        guard await asrEventually({ let inputs = await native.inputs.count, pending = await timer.pending; return inputs == 1 && pending == 1 }) else {
            await timer.release(); await native.releaseBegin(); Issue.record("Begin not held"); return
        }
        await core.beginClosing(); await core.hardwareDidClose()
        guard await asrEventually({ await timer.pending == 2 }) else {
            await timer.release(); await native.releaseBegin(); Issue.record("drain timer not installed"); return
        }
        await timer.release()
        #expect(await asrEventually { let shutdowns = await native.shutdowns, closed = await store.projection().isClosed; return shutdowns == 1 && closed })
        #expect(f.budget.usage.roots == 1 && FileManager.default.fileExists(atPath: f.input.configuration.modelDirectory))
        #expect(await f.policy.reservedBytes == 500)
        await native.releaseBegin()
        #expect(await asrEventually { let shutdowns = await native.shutdowns, reserved = await f.policy.reservedBytes; return shutdowns == 2 && reserved == 0 && f.budget.usage.roots == 0 })
    }

    @Test func abandonedPublishedPrefixPreservesCommittedTextAndTerminalGapCutoff() async {
        let f = LiveTranscriptFixture(), mic = f.epoch(), system = f.epoch(.system,origin: nil)
        let store = LiveTranscriptStore(identity: f.identity), owner = UUID()
        #expect(store.bindCaptureOwner(owner,accepting: { true }))
        #expect(await store.beginEpoch(owner: f.identity,epoch: mic) == .accepted)
        #expect(await store.beginEpoch(owner: f.identity,epoch: system) == .accepted)
        #expect(await store.admit(f.event(mic,0,f.progress(2))) == .accepted)
        let committed = f.segment(mic,0,0,1)
        #expect(await store.admit(f.event(mic,1,.committed(committed))) == .accepted)
        #expect(await store.admit(f.event(mic,2,.partial(.init(epochID: mic.id,source: .microphone,revision: 1,
            samples: .init(start: 16000,end: 32000),text: "Provisional")))) == .accepted)
        #expect(await store.admit(f.event(system,0,f.progress(2))) == .accepted)
        let before = await store.projection()
        #expect(await store.abandonCaptureOwner(UUID(),losses: []) == .rejected(.wrongOwner))
        #expect(await store.projection() == before)
        #expect(await store.abandonCaptureOwner(owner,losses: []) == .accepted)
        let projection = await store.projection(), snapshot = await store.snapshot()
        #expect(projection.isClosed && projection.partials.isEmpty && projection.segments == [committed])
        #expect(projection.lanes.allSatisfy { $0.availability == .unavailable && $0.settledSampleEnd == 32000 })
        #expect(snapshot.cutoffNanoseconds == 2_000_000_000)
        #expect(snapshot.coverage.contains { $0.interval.kind == .gap(.unavailable) && $0.interval.source == .microphone &&
            $0.includedMeeting == .init(startNanoseconds: 1_000_000_000,endNanoseconds: 2_000_000_000) })
        #expect(projection.coverage.contains { $0.kind == .gap(.unavailable) && $0.source == .system && $0.range.meeting == nil })
        #expect(await store.abandonCaptureOwner(owner,losses: []) == .duplicate)
        #expect(await store.projection() == projection)
    }

    @Test func identityBearingCoreCannotUseUnownedLegacyDispatch() async throws {
        let f = try ASRPreparedFixture(), native = ASRPreparedNative(); defer { f.files.remove() }
        let store = LiveTranscriptStore(identity: f.input.identity)
        let unowned = LiveCaptureSessionCoordinator(input: f.input,store: store,transport: native.transport,ingress: f.ingress)
        await #expect(throws: LiveProtocolError.invalidConfiguration) { try await unowned.start() }
        #expect(await native.inputs.isEmpty)
        #expect((await store.projection()).lanes.isEmpty && f.files.staged.isEmpty)
    }

    @Test func wrongQualifiedWeightsRejectBeforeTheActualCopy() async throws {
        let f = try ASRPreparedFixture(profileIdentity: ASRAssetsFixture.identity(fingerprint: String(repeating: "b",count: 64)))
        defer { f.files.remove() }
        await #expect(throws: LiveResourceRejection.unsupported) { _ = try await f.preparation().prepare() }
        #expect(f.files.staged.isEmpty && f.budget.usage.roots == 0 && f.budget.usage.workers == 0)
        #expect(await f.policy.reservedBytes == 0)
    }

    @Test func stopDuringActualHeldCopyClosesWithoutJoiningItsWorker() async throws {
        let gate = ASRCopyGate(), f = try ASRPreparedFixture(probe: { point,_ in if point == .afterCreateDirectory { await gate.hold() } })
        defer { f.files.remove() }
        let native = ASRPreparedNative(), store = LiveTranscriptStore(identity: f.input.identity), preparation = f.preparation()
        let core = LiveCaptureSessionCoordinator(input: f.input,store: store,transport: native.transport,
            drainDeadline: .seconds(300),preparationDeadline: .seconds(300),resources: f.policy,ingress: f.ingress,preparation: preparation)
        try await core.start()
        guard await asrEventually({ await gate.entered }) else { await gate.release(); Issue.record("copy not held"); return }
        await core.beginClosing(); await core.hardwareDidClose()
        #expect(await asrEventually { (await store.projection()).isClosed })
        #expect(await native.inputs.isEmpty)
        #expect(f.budget.usage.workers == 1 && f.budget.usage.roots == 1)
        #expect(await f.policy.reservedBytes == 0)
        await gate.release()
        #expect(await asrEventually { f.budget.usage.workers == 0 && f.budget.usage.roots == 0 && f.files.staged.isEmpty })
    }

    @Test func transferredSnapshotAndLeaseSurviveTerminalPrivacyUntilActualShutdown() async throws {
        let f = try ASRPreparedFixture(); defer { f.files.remove() }
        let native = ASRPreparedNative(), store = LiveTranscriptStore(identity: f.input.identity)
        await native.holdShutdown()
        let core = LiveCaptureSessionCoordinator(input: f.input,store: store,transport: native.transport,
            resources: f.policy,ingress: f.ingress,preparation: f.preparation())
        try await core.start()
        guard await asrEventually({ await core.readySources == [.microphone] }) else { await native.release(); Issue.record("not ready"); return }
        #expect(await native.inputs.first == f.input)
        #expect(FileManager.default.fileExists(atPath: f.input.configuration.modelDirectory))
        await native.fail()
        #expect(await asrEventually { await native.shutdowns == 1 })
        #expect(f.budget.usage.roots == 1 && FileManager.default.fileExists(atPath: f.input.configuration.modelDirectory))
        #expect(await f.policy.reservedBytes == 500)
        await native.release()
        #expect(await asrEventually { await f.policy.reservedBytes == 0 && f.budget.usage.roots == 0 })
    }

    @Test func losingLastActiveCoreInitiatesTeardownAndRetainsItsNativeAssetsThroughExit() async throws {
        let f = try ASRPreparedFixture(); defer { f.files.remove() }
        let native = ASRPreparedNative(), store = LiveTranscriptStore(identity: f.input.identity)
        await native.holdShutdown()
        func startAndDrop() async throws -> ASRWeakCore {
            let core = LiveCaptureSessionCoordinator(input: f.input,store: store,transport: native.transport,
                resources: f.policy,ingress: f.ingress,preparation: f.preparation())
            try await core.start()
            #expect(await asrEventually { await core.readySources == [.microphone] })
            return ASRWeakCore(core)
        }
        let weak = try await startAndDrop()
        #expect(await asrEventually { !weak.alive })
        #expect(await asrEventually { await native.shutdowns == 1 })
        #expect(f.budget.usage.roots == 1 && FileManager.default.fileExists(atPath: f.input.configuration.modelDirectory))
        #expect(await f.policy.reservedBytes == 500)
        #expect(await asrEventually { (await store.projection()).isClosed })
        await native.release()
        #expect(await asrEventually { await f.policy.reservedBytes == 0 && f.budget.usage.roots == 0 })
    }
}
