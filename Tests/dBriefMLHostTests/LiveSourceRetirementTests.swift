import Foundation
import Testing
import dBriefWire
@testable import dBriefMLHost

private func retirementEventually(_ predicate: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<1000 { if await predicate() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
    return false
}
private final class RetirementAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [LiveSessionEvent] = []
    private var dead: Set<Int> = []
    private var processed: Set<Int> = []
    private var entered: Set<String> = []
    func emit(_ event: LiveSessionEvent) { lock.withLock { frames.append(event) } }
    func destroy(_ id: Int) { lock.withLock { _ = dead.insert(id) } }
    func process(_ id: Int) { lock.withLock { _ = processed.insert(id) } }
    func destroyed(_ id: Int) -> Bool { lock.withLock { dead.contains(id) } }
    func didProcess(_ id: Int) -> Bool { lock.withLock { processed.contains(id) } }
    func enter(_ mode: String) { lock.withLock { _ = entered.insert(mode) } }
    func didEnter(_ mode: String) -> Bool { lock.withLock { entered.contains(mode) } }
    var events: [LiveSessionEvent] { lock.withLock { frames } }
    var lanes: [LiveLaneEvent] { events.compactMap { if case .lane(let e) = $0 { e } else { nil } } }
    func ready(_ scope: LiveLaneScope) -> Bool { lanes.contains { e in e.scope == scope && { if case .ready = e.payload { true } else { false } }() } }
    func ack(_ id: UUID) -> Bool { lanes.contains { if case .barrierCompleted(let actual,_,_) = $0.payload { actual == id } else { false } } }
}
private actor RetirementProbe {
    let release = LifetimeSignal()
    private(set) var calls = 0
    func hold(_ scope: LiveLaneScope) async {
        guard scope.source == .microphone else { return }
        calls += 1; await release.wait()
    }
}
private actor RetirementDecoder: NemotronStreamingDecoder {
    let id: Int, mode: String, audit: RetirementAudit, release: LifetimeSignal
    let partial: @Sendable (String) -> Void
    private var samples: [Float] = []
    init(id: Int, mode: String, audit: RetirementAudit, release: LifetimeSignal,
         partial: @escaping @Sendable (String) -> Void) {
        self.id = id; self.mode = mode; self.audit = audit; self.release = release; self.partial = partial
    }
    deinit { audit.destroy(id) }
    func process(samples: [Float]) async throws -> NemotronDecoderProgress {
        self.samples += samples; audit.process(id)
        if mode == "append" && id == 1 { audit.enter(mode); await release.wait() }
        partial("Native provisional")
        return .init(consumedSamples: 0,heldSamples: Int64(self.samples.count))
    }
    func finish() async throws -> NemotronDecoderOutput {
        if mode == "finish" && id == 1 { audit.enter(mode); await release.wait() }
        if mode == "fail-finish" && id == 1 { throw NemotronSessionError.unavailable }
        return .init(text: samples.isEmpty ? "" : "Native final",timings: [])
    }
}
private actor RetirementFactory: NemotronDecoderMaking {
    let mode: String, audit: RetirementAudit
    let release = LifetimeSignal()
    private var count = 0
    init(mode: String = "none", audit: RetirementAudit) { self.mode = mode; self.audit = audit }
    func makeDecoder(configuration: NemotronDecoderConfiguration, partial: @escaping @Sendable (String) -> Void) async throws -> any NemotronStreamingDecoder {
        count += 1; let id = count
        if mode == "prepare" && id == 1 { audit.enter(mode); await release.wait() }
        return RetirementDecoder(id: id,mode: mode,audit: audit,release: release,partial: partial)
    }
}
private struct RetirementFixture: Sendable {
    let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
    let micID = UUID(), systemID = UUID()
    func scope(_ source: LiveSource = .microphone) -> LiveLaneScope {
        .init(identity: identity,source: source,epochID: source == .microphone ? micID : systemID)
    }
    func epoch(_ source: LiveSource = .microphone, id: UUID? = nil) -> LiveEpoch {
        .init(id: id ?? (source == .microphone ? micID : systemID),source: source,engineRevision: "nemotron",language: "auto",meetingOriginNanoseconds: nil)
    }
    func begin(two: Bool = false) -> LiveSessionRequest {
        .begin(.init(identity: identity,configuration: .init(language: .auto,modelDirectory: "/private/models"),epochs: two ? [epoch(),epoch(.system)] : [epoch()]))
    }
    func packet(_ source: LiveSource = .microphone) throws -> LiveSessionRequest {
        .packet(try .init(scope: scope(source),sequence: 0,startSample: 0,samples: [Float](repeating: 1,count: 1600)))
    }
    func replacement(_ id: UUID) -> LiveSessionRequest { .replaceEpoch(identity: identity,oldEpochID: micID,epoch: epoch(id: id)) }
}

@Suite struct LiveSourceRetirementTests {
    @Test func idleHeldInputCannotBeReplacedBeforeActualCleanup() async throws {
        let f = RetirementFixture(), audit = RetirementAudit(), factory = RetirementFactory(audit: audit), probe = RetirementProbe()
        let helper = LiveASROrchestrator(loader: { _ in factory },emit: audit.emit,testingBeforeRetirement: probe.hold)
        defer { Task { await probe.release.signal(); _ = await helper.handle(.cancel(f.identity),requestID: UUID()) } }
        #expect(await helper.handle(f.begin(),requestID: UUID()) == .accepted)
        try #require(await retirementEventually { audit.ready(f.scope()) })
        #expect(try await helper.handle(f.packet(),requestID: UUID()) == .accepted)
        try #require(await retirementEventually { audit.lanes.contains { if case .progress(let p) = $0.payload { p.heldSamples == 1600 && p.inFlightSamples == 0 } else { false } } })
        #expect(await helper.handle(.cut(scope: f.scope(),nextPacketSequence: 1,sampleEnd: 1600,reason: .overload),requestID: UUID()) == .accepted)
        try #require(await retirementEventually { await probe.calls == 1 })
        let fresh = UUID()
        #expect(await helper.handle(f.replacement(fresh),requestID: UUID()) == .rejected(.unavailable))
        #expect(!audit.destroyed(1))
        await probe.release.signal()
        try #require(await retirementEventually { await helper.handle(f.replacement(fresh),requestID: UUID()) == .accepted })
        #expect(audit.destroyed(1))
        try #require(await retirementEventually { audit.ready(.init(identity: f.identity,source: .microphone,epochID: fresh)) })
    }

    @Test func aWindingDownWorkRecordSurvivesUntilItsActualTaskReturn() async throws {
        let f = RetirementFixture(), audit = RetirementAudit(), factory = RetirementFactory(audit: audit), probe = RetirementProbe()
        let helper = LiveASROrchestrator(loader: { _ in factory },emit: audit.emit,testingBeforeWorkReturn: probe.hold)
        defer { Task { await probe.release.signal(); _ = await helper.handle(.cancel(f.identity),requestID: UUID()) } }
        #expect(await helper.handle(f.begin(),requestID: UUID()) == .accepted)
        try #require(await retirementEventually { let calls = await probe.calls; return audit.ready(f.scope()) && calls == 1 })
        #expect(await helper.handle(.cut(scope: f.scope(),nextPacketSequence: 0,sampleEnd: 0,reason: .engineRestart),requestID: UUID()) == .accepted)
        let fresh = UUID()
        #expect(await helper.handle(f.replacement(fresh),requestID: UUID()) == .rejected(.unavailable))
        await probe.release.signal()
        try #require(await retirementEventually { await helper.handle(f.replacement(fresh),requestID: UUID()) == .accepted })
        #expect(audit.destroyed(1))
    }

    @Test(arguments: ["prepare","append","finish"])
    func cancellationIgnoringNativeOperationMustActuallyReturnBeforeReplacement(mode: String) async throws {
        let f = RetirementFixture(), audit = RetirementAudit(), factory = RetirementFactory(mode: mode,audit: audit)
        let helper = LiveASROrchestrator(loader: { _ in factory },emit: audit.emit)
        defer { Task { await factory.release.signal(); _ = await helper.handle(.cancel(f.identity),requestID: UUID()) } }
        #expect(await helper.handle(f.begin(),requestID: UUID()) == .accepted)
        if mode != "prepare" {
            try #require(await retirementEventually { audit.ready(f.scope()) })
            #expect(try await helper.handle(f.packet(),requestID: UUID()) == .accepted)
            if mode == "finish" {
                #expect(await helper.handle(.barrier(.init(scope: f.scope(),nextPacketSequence: 1,sampleEnd: 1600,kind: .utterance)),requestID: UUID()) == .accepted)
            }
        }
        try #require(await retirementEventually { audit.didEnter(mode) })
        let end: Int64 = mode == "prepare" ? 0 : 1600, sequence: UInt64 = mode == "prepare" ? 0 : 1
        #expect(await helper.handle(.cut(scope: f.scope(),nextPacketSequence: sequence,sampleEnd: end,reason: .engineRestart),requestID: UUID()) == .accepted)
        let fresh = UUID()
        #expect(await helper.handle(f.replacement(fresh),requestID: UUID()) == .rejected(.unavailable))
        await factory.release.signal()
        try #require(await retirementEventually { await helper.handle(f.replacement(fresh),requestID: UUID()) == .accepted })
        #expect(audit.destroyed(1))
        #expect(!audit.lanes.contains { if case .committed = $0.payload { true } else { false } })
    }

    @Test(arguments: [LiveFinishBarrier.Kind.pause,.finish])
    func terminalACKWaitsCleanupAndPauseImmediatelyPermitsReplacement(kind: LiveFinishBarrier.Kind) async throws {
        let f = RetirementFixture(), audit = RetirementAudit(), factory = RetirementFactory(audit: audit), probe = RetirementProbe()
        let helper = LiveASROrchestrator(loader: { _ in factory },emit: audit.emit,testingBeforeRetirement: probe.hold)
        defer { Task { await probe.release.signal(); _ = await helper.handle(.cancel(f.identity),requestID: UUID()) } }
        #expect(await helper.handle(f.begin(),requestID: UUID()) == .accepted)
        try #require(await retirementEventually { audit.ready(f.scope()) })
        #expect(try await helper.handle(f.packet(),requestID: UUID()) == .accepted)
        let id = UUID(), barrier = LiveFinishBarrier(scope: f.scope(),nextPacketSequence: 1,sampleEnd: 1600,kind: kind)
        #expect(await helper.handle(.barrier(barrier),requestID: id) == .accepted)
        try #require(await retirementEventually { await probe.calls == 1 })
        #expect(!audit.ack(id))
        #expect(await helper.handle(.barrier(barrier),requestID: id) == .accepted)
        #expect(await helper.handle(.cut(scope: f.scope(),nextPacketSequence: 2,sampleEnd: 3200,reason: .overload),requestID: UUID()) == .rejected(.outOfOrder))
        #expect(await helper.handle(.cut(scope: f.scope(),nextPacketSequence: 1,sampleEnd: 1600,reason: .engineRestart),requestID: UUID()) == .accepted)
        #expect(await probe.calls == 1)
        await probe.release.signal()
        try #require(await retirementEventually { audit.ack(id) })
        #expect(audit.destroyed(1))
        if kind == .pause {
            #expect(await helper.handle(f.replacement(UUID()),requestID: UUID()) == .accepted)
        } else {
            let before = audit.events
            #expect(await helper.handle(.barrier(barrier),requestID: id) == .accepted)
            #expect(audit.events == before && audit.events.last == .finished(f.identity))
        }
    }

    @Test func failureInsideNativeWorkStillRunsIndependentCleanupAndCompletesOriginalTerminal() async throws {
        let f = RetirementFixture(), audit = RetirementAudit(), factory = RetirementFactory(mode: "fail-finish",audit: audit)
        let helper = LiveASROrchestrator(loader: { _ in factory },emit: audit.emit)
        #expect(await helper.handle(f.begin(),requestID: UUID()) == .accepted)
        try #require(await retirementEventually { audit.ready(f.scope()) })
        #expect(try await helper.handle(f.packet(),requestID: UUID()) == .accepted)
        let id = UUID()
        #expect(await helper.handle(.barrier(.init(scope: f.scope(),nextPacketSequence: 1,sampleEnd: 1600,kind: .finish)),requestID: id) == .accepted)
        try #require(await retirementEventually { audit.ack(id) })
        #expect(audit.destroyed(1) && audit.events.last == .finished(f.identity))
        #expect(audit.lanes.contains { if case .settled(let coverage) = $0.payload { coverage.kind == .gap(.engineRestart) } else { false } })
        #expect(!audit.lanes.contains { if case .committed = $0.payload { true } else { false } })
    }

    @Test func heldCleanupDoesNotBlockHealthySourceOrMakeCancelJoinIt() async throws {
        let f = RetirementFixture(), audit = RetirementAudit(), factory = RetirementFactory(audit: audit), probe = RetirementProbe()
        let helper = LiveASROrchestrator(loader: { _ in factory },emit: audit.emit,testingBeforeRetirement: probe.hold)
        defer { Task { await probe.release.signal() } }
        #expect(await helper.handle(f.begin(two: true),requestID: UUID()) == .accepted)
        try #require(await retirementEventually { audit.ready(f.scope()) && audit.ready(f.scope(.system)) })
        #expect(await helper.handle(.cut(scope: f.scope(),nextPacketSequence: 0,sampleEnd: 0,reason: .engineRestart),requestID: UUID()) == .accepted)
        try #require(await retirementEventually { await probe.calls == 1 })
        #expect(try await helper.handle(f.packet(.system),requestID: UUID()) == .accepted)
        let id = UUID()
        #expect(await helper.handle(.barrier(.init(scope: f.scope(.system),nextPacketSequence: 1,sampleEnd: 1600,kind: .finish)),requestID: id) == .accepted)
        try #require(await retirementEventually { audit.ack(id) })
        #expect(await helper.handle(.cancel(f.identity),requestID: UUID()) == .accepted)
        #expect(await probe.calls == 1) // Accepted while its release is still held.
        let before = audit.events
        await probe.release.signal()
        try #require(await retirementEventually { audit.destroyed(1) && audit.destroyed(2) })
        #expect(audit.events == before && before.last == .finished(f.identity))
    }

    @Test func globalLoaderCannotPublishASuffixToASourceFinishedDuringLoading() async throws {
        let f = RetirementFixture(), audit = RetirementAudit(), factory = RetirementFactory(audit: audit), loaderRelease = LifetimeSignal()
        let helper = LiveASROrchestrator(loader: { _ in await loaderRelease.wait(); return factory },emit: audit.emit)
        defer { Task { await loaderRelease.signal(); _ = await helper.handle(.cancel(f.identity),requestID: UUID()) } }
        #expect(await helper.handle(f.begin(two: true),requestID: UUID()) == .accepted)
        let id = UUID()
        #expect(await helper.handle(.barrier(.init(scope: f.scope(),nextPacketSequence: 0,sampleEnd: 0,kind: .finish)),requestID: id) == .accepted)
        try #require(await retirementEventually { audit.ack(id) })
        let closedFrames = audit.lanes.filter { $0.scope == f.scope() }
        await loaderRelease.signal()
        try #require(await retirementEventually { audit.ready(f.scope(.system)) })
        #expect(audit.lanes.filter { $0.scope == f.scope() } == closedFrames)
        #expect(!audit.ready(f.scope()))
    }
}
