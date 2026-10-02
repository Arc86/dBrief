import Foundation
import Testing
import dBriefWire
@testable import dBriefMLHost

private final class LiveHelperAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LiveSessionEvent] = []
    func append(_ event: LiveSessionEvent) { lock.withLock { stored.append(event) } }
    var events: [LiveSessionEvent] { lock.withLock { stored } }
    var lanes: [LiveLaneEvent] { events.compactMap { if case .lane(let e) = $0 { e } else { nil } } }
    func wait(_ predicate: @Sendable ([LiveLaneEvent]) -> Bool) async -> Bool {
        for _ in 0..<200 { if predicate(lanes) { return true }; try? await Task.sleep(for: .milliseconds(5)) }
        return false
    }
}
private actor ChunkLiveDecoder: NemotronStreamingDecoder {
    let chunk: Int64, scripted: Bool, release: LifetimeSignal
    nonisolated let partial: @Sendable (String) -> Void
    private var count: Int64 = 0, sum: Float = 0
    init(chunk: Int, scripted: Bool, release: LifetimeSignal, partial: @escaping @Sendable (String) -> Void) {
        self.chunk = Int64(chunk); self.scripted = scripted; self.release = release; self.partial = partial
    }
    func process(samples: [Float]) async throws -> NemotronDecoderProgress {
        if samples.first == 9 { await release.wait() }
        count += Int64(samples.count); sum += samples.reduce(0,+)
        partial("Provisional")
        let consumed = scripted ? min(count,24000) : count / chunk * chunk
        return .init(consumedSamples: consumed, heldSamples: count-consumed)
    }
    func finish() async throws -> NemotronDecoderOutput { .init(text: sum == 0 ? "" : "Utterance \(Int(sum))", timings: []) }
}
private actor LiveFixtureFactory: NemotronDecoderMaking {
    let scripted: Bool, release: LifetimeSignal
    private var callbacks: [@Sendable (String) -> Void] = []
    init(scripted: Bool = false, release: LifetimeSignal = .init()) { self.scripted = scripted; self.release = release }
    func makeDecoder(configuration: NemotronDecoderConfiguration, partial: @escaping @Sendable (String) -> Void) async throws -> any NemotronStreamingDecoder {
        callbacks.append(partial)
        return ChunkLiveDecoder(chunk: configuration.chunkSamples, scripted: scripted, release: release, partial: partial)
    }
    func lateCallback() { callbacks.last?("Old callback") }
}
private struct LiveHelperFixture: Sendable {
    let identity = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
    let epochID = UUID()
    var scope: LiveLaneScope { .init(identity: identity, source: .microphone, epochID: epochID) }
    func epoch(_ source: LiveSource = .microphone, id: UUID? = nil) -> LiveEpoch {
        .init(id: id ?? epochID, source: source, engineRevision: "nemotron", language: "auto", meetingOriginNanoseconds: nil)
    }
    func begin(_ tier: Int = 1120, epochs: [LiveEpoch]? = nil) -> LiveSessionRequest {
        .begin(.init(identity: identity, configuration: .init(language: .auto, chunkMs: tier, modelDirectory: "/private/models"), epochs: epochs ?? [epoch()]))
    }
    func packet(_ sequence: UInt64, _ start: Int64, value: Float = 1, scope: LiveLaneScope? = nil) throws -> LiveSessionRequest {
        .packet(try .init(scope: scope ?? self.scope, sequence: sequence, startSample: start, samples: Array(repeating: value,count: 1600)))
    }
}

@Suite struct LiveHelperSessionTests {
    @Test func finalStopOfAPausedLanePreservesTheAlreadySettledPrefix() async throws {
        let f = LiveHelperFixture(), audit = LiveHelperAudit(), factory = LiveFixtureFactory()
        let helper = LiveASROrchestrator(loader: { _ in factory },emit: audit.append)
        #expect(await helper.handle(f.begin(),requestID: UUID()) == .accepted)
        try #require(await audit.wait { $0.contains { if case .ready = $0.payload { true } else { false } } })
        #expect(try await helper.handle(f.packet(0,0),requestID: UUID()) == .accepted)
        #expect(await helper.handle(.barrier(.init(scope: f.scope,nextPacketSequence: 1,sampleEnd: 1600,kind: .pause)),requestID: UUID()) == .accepted)
        try #require(await audit.wait { $0.contains { if case .barrierCompleted(_, .pause,1600) = $0.payload { true } else { false } } })
        let committedBefore = audit.lanes.filter { if case .committed = $0.payload { true } else { false } }
        let id = UUID(), finish = LiveFinishBarrier(scope: f.scope,nextPacketSequence: 1,sampleEnd: 1600,kind: .finish)
        #expect(await helper.handle(.barrier(finish),requestID: id) == .accepted)
        #expect(await audit.wait { $0.contains { if case .closed(1600) = $0.payload { true } else { false } } })
        #expect(audit.events.contains(.finished(f.identity)))
        #expect(audit.lanes.filter { if case .committed = $0.payload { true } else { false } } == committedBefore)
        let beforeRetry = audit.events
        #expect(await helper.handle(.barrier(finish),requestID: id) == .accepted)
        #expect(audit.events == beforeRetry)
    }
    @Test(arguments: [false,true]) func completedFinalBarrierRetriesAreIdempotent(twoLanes: Bool) async throws {
        let f = LiveHelperFixture(), audit = LiveHelperAudit(), factory = LiveFixtureFactory()
        let system = f.epoch(.system,id: UUID())
        let helper = LiveASROrchestrator(loader: { _ in factory },emit: audit.append)
        #expect(await helper.handle(f.begin(epochs: twoLanes ? [f.epoch(),system] : nil),requestID: UUID()) == .accepted)
        guard await audit.wait({ $0.filter { if case .ready = $0.payload { true } else { false } }.count == (twoLanes ? 2 : 1) }) else { Issue.record("no ready"); return }
        let micID = UUID(), micBarrier = LiveFinishBarrier(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,kind: .finish)
        #expect(await helper.handle(.barrier(micBarrier),requestID: micID) == .accepted)
        if twoLanes {
            guard await audit.wait({ $0.contains { if case .closed = $0.payload { true } else { false } } }) else { Issue.record("mic not closed"); return }
            let systemID = UUID(), barrier = LiveFinishBarrier(scope: .init(identity: f.identity,source: .system,epochID: system.id),nextPacketSequence: 0,sampleEnd: 0,kind: .finish)
            #expect(await helper.handle(.barrier(barrier),requestID: systemID) == .accepted)
            #expect(await audit.wait { $0.filter { if case .closed = $0.payload { true } else { false } }.count == 2 })
            let before = audit.events
            #expect(await helper.handle(.barrier(barrier),requestID: systemID) == .accepted)
            #expect(audit.events == before)
        } else { #expect(await audit.wait { $0.contains { if case .closed = $0.payload { true } else { false } } }) }
        let before = audit.events
        #expect(await helper.handle(.barrier(micBarrier),requestID: micID) == .accepted)
        #expect(audit.events == before)
    }
    @Test(arguments: [560,1120,2240]) func creditsAdmitAWholeChunkAndTrackActualHeldSamples(tier: Int) async throws {
        let f = LiveHelperFixture(), audit = LiveHelperAudit(), factory = LiveFixtureFactory()
        let helper = LiveASROrchestrator(loader: { _ in factory }, emit: audit.append)
        #expect(await helper.handle(f.begin(tier), requestID: UUID()) == .accepted)
        guard await audit.wait({ $0.contains { if case .ready = $0.payload { true } else { false } } }) else { Issue.record("no ready"); return }
        let count = (tier * 16 + 1599) / 1600
        for i in 0..<count { #expect(try await helper.handle(f.packet(UInt64(i),Int64(i*1600)), requestID: UUID()) == .accepted) }
        let total = Int64(count * 1600), chunk = Int64(tier * 16)
        #expect(await audit.wait { events in events.contains { if case .progress(let p) = $0.payload { p.consumedSampleEnd == chunk && p.inFlightSamples == 0 && p.queuedSamples == 0 } else { false } } })
        let progress = audit.lanes.compactMap { if case .progress(let p) = $0.payload { p } else { nil } }.last
        #expect(progress?.admittedSampleEnd == total && progress?.heldSamples == total - chunk)
        #expect(progress?.creditSamples == Int64(tier*16+32000) - (total-chunk))
        #expect(!audit.lanes.contains { if case .committed = $0.payload { true } else { false } })
        let barrierID = UUID()
        #expect(await helper.handle(.barrier(.init(scope: f.scope, nextPacketSequence: UInt64(count), sampleEnd: total, kind: .finish)), requestID: barrierID) == .accepted)
        #expect(await audit.wait { $0.contains { if case .barrierCompleted(let id, .finish, _) = $0.payload { id == barrierID } else { false } } })
        let committed = audit.lanes.compactMap { if case .committed(let s) = $0.payload { s } else { nil } }
        #expect(committed.first?.range.samples == .init(start: 0,end: total))
        #expect(audit.events.contains(.finished(f.identity)))
    }

    @Test func consumedProvisionalCutPreservesPrefixAndRequiresFreshEpoch() async throws {
        let f = LiveHelperFixture(), audit = LiveHelperAudit(), factory = LiveFixtureFactory(scripted: true)
        let helper = LiveASROrchestrator(loader: { _ in factory }, emit: audit.append)
        #expect(await helper.handle(f.begin(),requestID: UUID()) == .accepted)
        guard await audit.wait({ $0.contains { if case .ready = $0.payload { true } else { false } } }) else { Issue.record("no ready"); return }
        for i in 0..<10 { #expect(try await helper.handle(f.packet(UInt64(i),Int64(i*1600)),requestID: UUID()) == .accepted) }
        #expect(await helper.handle(.barrier(.init(scope: f.scope,nextPacketSequence: 10,sampleEnd: 16000,kind: .utterance)),requestID: UUID()) == .accepted)
        guard await audit.wait({ $0.filter { if case .ready = $0.payload { true } else { false } }.count == 2 }) else { Issue.record("no replacement"); return }
        for i in 10..<30 { #expect(try await helper.handle(f.packet(UInt64(i),Int64(i*1600)),requestID: UUID()) == .accepted) }
        #expect(await audit.wait { $0.contains { if case .progress(let p) = $0.payload { p.consumedSampleEnd == 40000 && p.heldSamples == 8000 } else { false } } })
        #expect(await helper.handle(.cut(scope: f.scope,nextPacketSequence: 30,sampleEnd: 48000,reason: .overload),requestID: UUID()) == .accepted)
        await factory.lateCallback()
        #expect(try await helper.handle(f.packet(30,48000),requestID: UUID()) == .rejected(.unavailable))
        let newID = UUID()
        var replaced = false
        for _ in 0..<200 {
            if await helper.handle(.replaceEpoch(identity: f.identity,oldEpochID: f.epochID,epoch: f.epoch(id: newID)),requestID: UUID()) == .accepted { replaced = true; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(replaced)
        let newScope = LiveLaneScope(identity: f.identity,source: .microphone,epochID: newID)
        #expect(await audit.wait { $0.contains { event in event.scope == newScope && { if case .ready = event.payload { true } else { false } }() } })
        #expect(try await helper.handle(f.packet(0,0,value: 2,scope: newScope),requestID: UUID()) == .accepted)
        #expect(await helper.handle(.barrier(.init(scope: newScope,nextPacketSequence: 1,sampleEnd: 1600,kind: .finish)),requestID: UUID()) == .accepted)
        #expect(await audit.wait { $0.contains { event in event.scope == newScope && { if case .closed = event.payload { true } else { false } }() } })
        let committed = audit.lanes.compactMap { if case .committed(let s) = $0.payload { s } else { nil } }
        #expect(committed.count == 2 && committed[0].text == "Utterance 16000" && committed[1].text == "Utterance 3200")
        let gaps = audit.lanes.compactMap { if case .settled(let s) = $0.payload, s.kind == .gap(.overload) { s.range.samples } else { nil } }
        #expect(gaps == [.init(start: 16000,end: 48000), .init(start: 48000,end: 49600)])
        #expect(!audit.lanes.contains { if case .partial(let p) = $0.payload { p.text == "Old callback" } else { false } })
    }

    @Test func oneStalledLaneCannotAccumulateUnboundedAudioOrBlockAnother() async throws {
        let f = LiveHelperFixture(), audit = LiveHelperAudit(), release = LifetimeSignal(), factory = LiveFixtureFactory(release: release)
        let system = f.epoch(.system,id: UUID()), systemScope = LiveLaneScope(identity: f.identity,source: .system,epochID: system.id)
        let helper = LiveASROrchestrator(loader: { _ in factory },emit: audit.append)
        #expect(await helper.handle(f.begin(2240,epochs: [f.epoch(),system]),requestID: UUID()) == .accepted)
        guard await audit.wait({ $0.filter { if case .ready = $0.payload { true } else { false } }.count == 2 }) else { Issue.record("no two ready lanes"); return }
        for i in 0..<44 { _ = try await helper.handle(f.packet(UInt64(i),Int64(i*1600),value: 9),requestID: UUID()) }
        #expect(audit.lanes.contains { event in event.scope == f.scope && { if case .needsEpochReplacement = event.payload { true } else { false } }() })
        for p in audit.lanes.compactMap({ if case .progress(let p) = $0.payload { p } else { nil } }) {
            #expect(p.queuedSamples+p.inFlightSamples+p.heldSamples <= 67840)
        }
        #expect(try await helper.handle(f.packet(0,0,value: 2,scope: systemScope),requestID: UUID()) == .accepted)
        #expect(await helper.handle(.barrier(.init(scope: systemScope,nextPacketSequence: 1,sampleEnd: 1600,kind: .finish)),requestID: UUID()) == .accepted)
        #expect(await audit.wait { $0.contains { event in event.scope == systemScope && { if case .committed = event.payload { true } else { false } }() } })
        #expect(await helper.handle(.cancel(f.identity),requestID: UUID()) == .accepted)
        await release.signal()
        #expect(audit.events.contains(.finished(f.identity)))
    }

    @Test func wrongOwnerDuplicateAndOutOfOrderCommandsCannotMutateSession() async throws {
        let f = LiveHelperFixture(), audit = LiveHelperAudit(), factory = LiveFixtureFactory()
        let helper = LiveASROrchestrator(loader: { _ in factory },emit: audit.append)
        #expect(await helper.handle(f.begin(),requestID: UUID()) == .accepted)
        guard await audit.wait({ $0.contains { if case .ready = $0.payload { true } else { false } } }) else { Issue.record("no ready"); return }
        #expect(try await helper.handle(f.packet(1,0),requestID: UUID()) == .rejected(.outOfOrder))
        #expect(try await helper.handle(f.packet(0,0),requestID: UUID()) == .accepted)
        #expect(try await helper.handle(f.packet(0,0),requestID: UUID()) == .rejected(.outOfOrder))
        let foreign = LiveLaneScope(identity: .init(recordingID: UUID(),captureSessionID: f.identity.captureSessionID),source: .microphone,epochID: f.epochID)
        #expect(try await helper.handle(f.packet(1,1600,scope: foreign),requestID: UUID()) == .rejected(.staleScope))
        #expect(await helper.handle(.barrier(.init(scope: f.scope,nextPacketSequence: 2,sampleEnd: 1600,kind: .finish)),requestID: UUID()) == .rejected(.outOfOrder))
        #expect(await helper.handle(.barrier(.init(scope: f.scope,nextPacketSequence: 1,sampleEnd: 1600,kind: .finish)),requestID: UUID()) == .accepted)
        #expect(await audit.wait { $0.contains { if case .closed = $0.payload { true } else { false } } })
    }
    @Test func inputDuringPreparationIsAnExactGapAndRequiresReplacement() async throws {
        let f = LiveHelperFixture(), audit = LiveHelperAudit(), release = LifetimeSignal(), factory = LiveFixtureFactory()
        let helper = LiveASROrchestrator(loader: { _ in await release.wait(); return factory },emit: audit.append)
        #expect(await helper.handle(f.begin(),requestID: UUID()) == .accepted)
        #expect(try await helper.handle(f.packet(0,0),requestID: UUID()) == .rejected(.unavailable))
        let gaps = audit.lanes.compactMap { if case .settled(let c) = $0.payload { c } else { nil } }
        #expect(gaps.count == 1 && gaps[0].kind == .gap(.preparation) && gaps[0].range.samples == .init(start: 0,end: 1600))
        let newID = UUID(), epoch = f.epoch(id: newID)
        #expect(await helper.handle(.replaceEpoch(identity: f.identity,oldEpochID: f.epochID,epoch: epoch),requestID: UUID()) == .rejected(.unavailable))
        await release.signal()
        var replaced = false
        for _ in 0..<200 {
            if await helper.handle(.replaceEpoch(identity: f.identity,oldEpochID: f.epochID,epoch: epoch),requestID: UUID()) == .accepted { replaced = true; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(replaced)
        #expect(await audit.wait { $0.contains { event in event.scope.epochID == newID && { if case .ready = event.payload { true } else { false } }() } })
        #expect(!audit.lanes.contains { event in event.scope == f.scope && { if case .ready = event.payload { true } else { false } }() })
        _ = await helper.handle(.cancel(f.identity),requestID: UUID())
    }

    @Test func preparationFailureAndCancellationIgnoringLoadCannotPublishLateReady() async throws {
        let f = LiveHelperFixture(), audit = LiveHelperAudit(), release = LifetimeSignal(), factory = LiveFixtureFactory()
        let helper = LiveASROrchestrator(loader: { _ in await release.wait(); return factory },emit: audit.append)
        #expect(await helper.handle(f.begin(),requestID: UUID()) == .accepted)
        let started = ContinuousClock.now
        #expect(await helper.handle(.cancel(f.identity),requestID: UUID()) == .accepted)
        #expect(started.duration(to: .now) < .seconds(1))
        let before = audit.events
        await release.signal(); try await Task.sleep(for: .milliseconds(30))
        #expect(audit.events == before && audit.events.contains(.finished(f.identity)))
        let failedAudit = LiveHelperAudit()
        let failed = LiveASROrchestrator(loader: { _ in throw LiveProtocolError.unavailable },emit: failedAudit.append)
        #expect(await failed.handle(f.begin(),requestID: UUID()) == .accepted)
        for _ in 0..<200 { if failedAudit.events.contains(.failed(f.identity,.unavailable)) { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(failedAudit.events.contains(.failed(f.identity,.unavailable)))
        #expect(!failedAudit.lanes.contains { if case .ready = $0.payload { true } else { false } })
    }

    @Test func pauseSettlesSilenceAndResumeUsesANewEpoch() async throws {
        let f = LiveHelperFixture(), audit = LiveHelperAudit(), factory = LiveFixtureFactory()
        let helper = LiveASROrchestrator(loader: { _ in factory },emit: audit.append)
        #expect(await helper.handle(f.begin(),requestID: UUID()) == .accepted)
        guard await audit.wait({ $0.contains { if case .ready = $0.payload { true } else { false } } }) else { Issue.record("no ready"); return }
        #expect(try await helper.handle(f.packet(0,0,value: 0),requestID: UUID()) == .accepted)
        #expect(await helper.handle(.barrier(.init(scope: f.scope,nextPacketSequence: 1,sampleEnd: 1600,kind: .pause)),requestID: UUID()) == .accepted)
        #expect(await audit.wait { $0.contains { if case .barrierCompleted(_, .pause,1600) = $0.payload { true } else { false } } })
        #expect(audit.lanes.contains { if case .settled(let c) = $0.payload { c.kind == .processedSilence && c.range.samples == .init(start: 0,end: 1600) } else { false } })
        #expect(try await helper.handle(f.packet(1,1600),requestID: UUID()) == .rejected(.closed))
        let newID = UUID(), newScope = LiveLaneScope(identity: f.identity,source: .microphone,epochID: newID)
        var replaced = false
        for _ in 0..<200 {
            if await helper.handle(.replaceEpoch(identity: f.identity,oldEpochID: f.epochID,epoch: f.epoch(id: newID)),requestID: UUID()) == .accepted { replaced = true; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(replaced)
        #expect(await audit.wait { $0.contains { event in event.scope == newScope && { if case .ready = event.payload { true } else { false } }() } })
        #expect(try await helper.handle(f.packet(0,0,value: 2,scope: newScope),requestID: UUID()) == .accepted)
        #expect(await helper.handle(.barrier(.init(scope: newScope,nextPacketSequence: 1,sampleEnd: 1600,kind: .finish)),requestID: UUID()) == .accepted)
        #expect(await audit.wait { $0.contains { event in event.scope == newScope && { if case .closed = event.payload { true } else { false } }() } })
        #expect(audit.lanes.filter { if case .committed = $0.payload { true } else { false } }.count == 1)
    }

}
