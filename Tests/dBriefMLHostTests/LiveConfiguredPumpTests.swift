import Foundation
import Testing
import dBriefWire
@testable import dBriefMLHost

private struct PumpAppend: Sendable { let decoder: Int; let count: Int; let total: Int64; let checksum: Float }
private final class PumpAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LiveSessionEvent] = []
    private var made = 0, calls: [PumpAppend] = [], finishes: [Int64] = [], disposed = 0
    private var tail = false, install = false, activation = false
    private var asrLoad = false, vadLoads = 0, loadReturn = false
    private var nativeCalls: [LiveSource:Int] = [:], nativeReturns: [LiveSource:Int] = [:]
    private var modelHandles = 0, sourceDisposals: [LiveSource:Int] = [:]
    private var windowChecksums: [LiveSource:[Float]] = [:]
    private var heldInstallations: Set<UUID> = []
    func emit(_ event: LiveSessionEvent) { lock.withLock { events.append(event) } }
    var lanes: [LiveLaneEvent] { lock.withLock { events.compactMap { if case .lane(let event) = $0 { event } else { nil } } } }
    var terminal: Bool { lock.withLock { events.contains { if case .finished = $0 { true } else { false } } } }
    func make() -> Int { lock.withLock { made += 1; return made } }
    var decoderCount: Int { lock.withLock { made } }
    func append(_ call: PumpAppend) { lock.withLock { calls.append(call) } }
    var appends: [PumpAppend] { lock.withLock { calls } }
    func finish(_ total: Int64) { lock.withLock { finishes.append(total) } }
    var finishEnds: [Int64] { lock.withLock { finishes } }
    func packetDisposed(_ scope: LiveLaneScope? = nil) { lock.withLock {
        disposed += 1
        if let scope { sourceDisposals[scope.source,default: 0] += 1 }
    } }
    var disposedCount: Int { lock.withLock { disposed } }
    func disposals(_ source: LiveSource) -> Int { lock.withLock { sourceDisposals[source,default: 0] } }
    func tailHeld() { lock.withLock { tail = true } }
    var isTailHeld: Bool { lock.withLock { tail } }
    func installHeld(_ id: UUID? = nil) { lock.withLock { install = true; if let id { heldInstallations.insert(id) } } }
    var isInstallHeld: Bool { lock.withLock { install } }
    func heldInstallation(_ id: UUID) -> Bool { lock.withLock { heldInstallations.contains(id) } }
    func activationHeld() { lock.withLock { activation = true } }
    var isActivationHeld: Bool { lock.withLock { activation } }
    func asrLoadHeld() { lock.withLock { asrLoad = true } }
    var isASRLoadHeld: Bool { lock.withLock { asrLoad } }
    func vadLoadEntered() { lock.withLock { vadLoads += 1 } }
    var vadLoadCount: Int { lock.withLock { vadLoads } }
    func loadingReturned() { lock.withLock { loadReturn = true } }
    var hasLoadingReturned: Bool { lock.withLock { loadReturn } }
    func nativeEntered(_ source: LiveSource) { lock.withLock { nativeCalls[source,default: 0] += 1 } }
    func nativeReturned(_ source: LiveSource) { lock.withLock { nativeReturns[source,default: 0] += 1 } }
    func predictions(_ source: LiveSource) -> Int { lock.withLock { nativeCalls[source,default: 0] } }
    func returnedPredictions(_ source: LiveSource) -> Int { lock.withLock { nativeReturns[source,default: 0] } }
    func modelMade() { lock.withLock { modelHandles += 1 } }
    var modelCount: Int { lock.withLock { modelHandles } }
    func windowInput(_ source: LiveSource,_ input: LiveVADNativeInput) { lock.withLock {
        windowChecksums[source,default: []].append(input.audio.suffix(4096).reduce(0,+))
    } }
    func checksums(_ source: LiveSource) -> [Float] { lock.withLock { windowChecksums[source,default: []] } }
    var ready: Bool { lanes.contains { if case .ready = $0.payload { true } else { false } } }
    var progresses: [LiveHelperProgress] { lanes.compactMap { if case .progress(let p) = $0.payload { p } else { nil } } }
    var modules: [LiveVADModuleEvent] { lanes.compactMap { if case .vad(let value) = $0.payload { value } else { nil } } }
}
private actor PumpDecoder: NemotronStreamingDecoder {
    let id: Int, audit: PumpAudit, finishGate: LifetimeSignal?
    let partial: @Sendable (String) -> Void
    private var total: Int64 = 0
    init(id: Int,audit: PumpAudit,finishGate: LifetimeSignal?,partial: @escaping @Sendable (String) -> Void) {
        self.id = id; self.audit = audit; self.finishGate = finishGate; self.partial = partial
    }
    func process(samples: [Float]) async throws -> NemotronDecoderProgress {
        total += Int64(samples.count); audit.append(.init(decoder: id,count: samples.count,total: total,checksum: samples.reduce(0,+)))
        partial("prefix \(total)")
        return .init(consumedSamples: total,heldSamples: 0)
    }
    func finish() async throws -> NemotronDecoderOutput {
        audit.finish(total)
        if id == 1 { await finishGate?.wait() }
        return .init(text: "decoder \(id)",timings: [])
    }
}
private struct PumpFactory: NemotronDecoderMaking {
    let audit: PumpAudit, finishGate: LifetimeSignal?
    func makeDecoder(configuration: NemotronDecoderConfiguration,partial: @escaping @Sendable (String) -> Void) async throws -> any NemotronStreamingDecoder {
        PumpDecoder(id: audit.make(),audit: audit,finishGate: finishGate,partial: partial)
    }
}
private actor PumpVADHandle: LiveVADModelHandle {
    nonisolated let assets: LiveVADModelAssets
    let source: LiveSource, audit: PumpAudit?, gate: LifetimeSignal?, failAt: Int?
    private var calls = 0
    init(_ assets: LiveVADModelAssets,source: LiveSource,audit: PumpAudit?,gate: LifetimeSignal?,failAt: Int?) {
        self.assets = assets; self.source = source; self.audit = audit; self.gate = gate; self.failAt = failAt
        audit?.modelMade()
    }
    func validate(_ contract: LiveVADModelContract) throws { try contract.validate(VADLoadFixture.description) }
    func predict(_ input: LiveVADNativeInput) async throws -> LiveVADNativeOutput {
        calls += 1
        audit?.nativeEntered(source)
        audit?.windowInput(source,input)
        defer { audit?.nativeReturned(source) }
        if source == .microphone { await gate?.wait() }
        if source == .microphone, calls == failAt { throw LiveVADModelError.invalidModel }
        return try .init(probability: calls == 1 ? 1 : 0,
            hiddenState: [Float](repeating: Float(calls),count: 128),cellState: [Float](repeating: 0,count: 128))
    }
}
private actor PumpHandleLoader {
    private var sources: [LiveSource]
    let audit: PumpAudit?, gate: LifetimeSignal?, failAt: Int?
    init(sources: [LiveSource],audit: PumpAudit?,gate: LifetimeSignal?,failAt: Int?) {
        self.sources = sources; self.audit = audit; self.gate = gate; self.failAt = failAt
    }
    func make(_ assets: LiveVADModelAssets) throws -> PumpVADHandle {
        guard !sources.isEmpty else { throw LiveProtocolError.invalidConfiguration }
        return PumpVADHandle(assets,source: sources.removeFirst(),audit: audit,gate: gate,failAt: failAt)
    }
}
private struct PumpFixture: Sendable {
    let scope = LiveLaneScope(identity: .init(recordingID: UUID(),captureSessionID: UUID()),source: .microphone,epochID: UUID())
    let systemID = UUID()
    var systemScope: LiveLaneScope { .init(identity: scope.identity,source: .system,epochID: systemID) }
    func epoch(id: UUID? = nil,source: LiveSource = .microphone) -> LiveEpoch {
        .init(id: id ?? (source == .microphone ? scope.epochID : systemID),source: source,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
    }
    func begin(_ assets: VADLoadFixture,both: Bool = false,chunkMs: Int = 560) -> LiveSessionBegin {
        .init(identity: scope.identity,configuration: .init(language: .auto,chunkMs: chunkMs,modelDirectory: "/fixture/asr"),epochs: both ? [epoch(),epoch(source: .system)] : [epoch()],vad: assets.configuration)
    }
    func load(_ input: LiveSessionBegin,_ fixture: VADLoadFixture,audit: PumpAudit? = nil,gate: LifetimeSignal? = nil,failAt: Int? = nil) async throws -> LiveVADModelFactory {
        let assets = try await fixture.assets()
        let loader = PumpHandleLoader(sources: input.epochs.map(\.source),audit: audit,gate: gate,failAt: failAt)
        return try await .load(configuration: input.vad!,sources: input.epochs.map(\.source),assets: assets) { owner,_ in
            try await loader.make(owner)
        }
    }
    func packet(_ sequence: UInt64,start: Int64,count: Int = 3200,scope: LiveLaneScope? = nil,value: Float = 1) throws -> LiveSessionRequest {
        .packet(try .init(scope: scope ?? self.scope,sequence: sequence,startSample: start,samples: [Float](repeating: value,count: count)))
    }
    func barrier(end: Int64,sequence: UInt64,kind: LiveFinishBarrier.Kind,scope: LiveLaneScope? = nil) -> LiveSessionRequest {
        .barrier(.init(scope: scope ?? self.scope,nextPacketSequence: sequence,sampleEnd: end,kind: kind))
    }
}
private func pumpEventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<500 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(2)) }
    return false
}

@Suite struct LiveConfiguredPumpTests {
    @Test(arguments: [false,true]) func acceptedEpochBudgetAlsoBoundsLegacyReplacements(configured: Bool) async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit()
        let helper = LiveASROrchestrator(loader: { _ in PumpFactory(audit: audit,finishGate: nil) },
            vadLoader: { input in try await f.load(input,a) },emit: audit.emit,testingEpochLimit: 2)
        defer { Task { _ = await helper.handle(.cancel(f.scope.identity),requestID: UUID()) } }
        let base = f.begin(a)
        let input = LiveSessionBegin(identity: base.identity,configuration: base.configuration,epochs: base.epochs,vad: configured ? base.vad : nil)
        #expect(await helper.handle(.begin(input),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.ready })
        let pauseID = UUID()
        #expect(await helper.handle(f.barrier(end: 0,sequence: 0,kind: .pause),requestID: pauseID) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            if case .barrierCompleted(let id,.pause,0) = event.payload { return id == pauseID }; return false
        } })
        let fresh = f.epoch(id: UUID()), scope = LiveLaneScope(identity: f.scope.identity,source: .microphone,epochID: fresh.id)
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: fresh),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            guard event.scope == scope else { return false }
            if case .ready = event.payload { return true }; return false
        } })
        let secondPause = UUID(), barrier = f.barrier(end: 0,sequence: 0,kind: .pause,scope: scope)
        #expect(await helper.handle(barrier,requestID: secondPause) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            if case .barrierCompleted(let id,.pause,0) = event.payload { return id == secondPause }; return false
        } })
        #expect(await helper.handle(barrier,requestID: secondPause) == .accepted)
        let published = audit.lanes, made = audit.decoderCount
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: fresh.id,epoch: f.epoch(id: UUID())),requestID: UUID()) == .rejected(.unavailable))
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: fresh.id,epoch: f.epoch()),requestID: UUID()) == .rejected(.invalidConfiguration))
        #expect(audit.lanes == published && audit.decoderCount == made)
        #expect(await helper.handle(f.barrier(end: 0,sequence: 0,kind: .finish,scope: scope),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.terminal })
    }

    @Test func failedVADLoaderDegradesBothSourcesAndNeverReloadsOnReplacement() async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit()
        let helper = LiveASROrchestrator(loader: { _ in PumpFactory(audit: audit,finishGate: nil) },
            vadLoader: { _ in audit.vadLoadEntered(); throw LiveVADModelError.invalidModel },emit: audit.emit)
        defer { Task { _ = await helper.handle(.cancel(f.scope.identity),requestID: UUID()) } }
        let input = f.begin(a,both: true)
        #expect(await helper.handle(.begin(input),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.lanes.filter { if case .ready = $0.payload { true } else { false } }.count == 2 })
        #expect(audit.vadLoadCount == 1 && audit.modelCount == 0)
        for scope in [f.scope,f.systemScope] {
            let statuses = audit.lanes.filter { $0.scope == scope }.compactMap { event -> LiveVADModuleEvent? in
                if case .vad(let value) = event.payload { return value }; return nil
            }
            try #require(statuses.count == 2)
            guard case .preparing = statuses[0], case .degraded(_,nil,0) = statuses[1] else { Issue.record("Loader failure did not explicitly degrade the source"); return }
            #expect(try await helper.handle(f.packet(0,start: 0,scope: scope),requestID: UUID()) == .accepted)
        }
        try #require(await pumpEventually { [f.scope,f.systemScope].allSatisfy { scope in
            audit.lanes.contains { event in
                guard event.scope == scope else { return false }
                if case .progress(let p) = event.payload { return p.consumedSampleEnd == 3200 && p.effectiveASRConsumedSampleEnd == 3200 && p.creditSamples == Int64(input.configuration.pendingSampleLimit) }; return false
            }
        } })
        let pauseID = UUID()
        #expect(await helper.handle(f.barrier(end: 3200,sequence: 1,kind: .pause),requestID: pauseID) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            if case .barrierCompleted(let id,.pause,3200) = event.payload { return id == pauseID }; return false
        } })
        let fresh = f.epoch(id: UUID()), scope = LiveLaneScope(identity: f.scope.identity,source: .microphone,epochID: fresh.id)
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: fresh),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            guard event.scope == scope else { return false }
            if case .ready = event.payload { return true }; return false
        } })
        let statuses = audit.lanes.filter { $0.scope == scope }.compactMap { event -> LiveVADModuleEvent? in
            if case .vad(let value) = event.payload { return value }; return nil
        }
        try #require(statuses.count == 1)
        guard case .degraded(_,nil,0) = statuses[0] else { Issue.record("Loader failure reactivated a fresh source"); return }
        #expect(try await helper.handle(f.packet(0,start: 0,scope: scope),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            guard event.scope == scope else { return false }
            if case .progress(let p) = event.payload { return p.consumedSampleEnd == 3200 }; return false
        } })
        #expect(audit.vadLoadCount == 1 && audit.modelCount == 0)
    }

    @Test func canceledReservationsExhaustFiniteEpochBudgetWithoutEvictionOrMutation() async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit(), firstGate = LifetimeSignal(), secondGate = LifetimeSignal()
        let first = f.epoch(id: UUID()), second = f.epoch(id: UUID())
        let helper = LiveASROrchestrator(loader: { _ in PumpFactory(audit: audit,finishGate: nil) },
            vadLoader: { input in try await f.load(input,a) },emit: audit.emit,testingEpochLimit: 3,
            testingBeforeInstall: { _,scope in
                if scope.epochID == first.id { audit.installHeld(first.id); await firstGate.wait() }
                if scope.epochID == second.id { audit.installHeld(second.id); await secondGate.wait() }
            })
        defer { Task {
            await firstGate.signal(); await secondGate.signal()
            _ = await helper.handle(.cancel(f.scope.identity),requestID: UUID())
        } }
        #expect(await helper.handle(.begin(f.begin(a)),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.ready })
        let pauseID = UUID()
        #expect(await helper.handle(f.barrier(end: 0,sequence: 0,kind: .pause),requestID: pauseID) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            if case .barrierCompleted(let id,.pause,0) = event.payload { return id == pauseID }; return false
        } })
        for (epoch,gate) in [(first,firstGate),(second,secondGate)] {
            let attempt = Task { await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: epoch),requestID: UUID()) }
            try #require(await pumpEventually { audit.heldInstallation(epoch.id) })
            attempt.cancel(); await gate.signal()
            #expect(await attempt.value == .rejected(.unavailable))
        }
        let published = audit.lanes
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: f.epoch(id: UUID())),requestID: UUID()) == .rejected(.unavailable))
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: first),requestID: UUID()) == .rejected(.invalidConfiguration))
        #expect(audit.lanes == published)
        #expect(await helper.handle(f.barrier(end: 0,sequence: 0,kind: .finish),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.terminal })
    }

    @Test func nativeFailureKeepsASRAndPeerActiveWithoutReloadingFailedSource() async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit()
        let helper = LiveASROrchestrator(loader: { _ in PumpFactory(audit: audit,finishGate: nil) },
            vadLoader: { input in try await f.load(input,a,audit: audit,failAt: 2) },emit: audit.emit)
        defer { Task { _ = await helper.handle(.cancel(f.scope.identity),requestID: UUID()) } }
        #expect(await helper.handle(.begin(f.begin(a,both: true)),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.lanes.filter { if case .ready = $0.payload { true } else { false } }.count == 2 })
        for i in 0..<3 {
            #expect(try await helper.handle(f.packet(UInt64(i),start: Int64(i*3200)),requestID: UUID()) == .accepted)
        }
        try #require(await pumpEventually { audit.lanes.contains { event in
            guard event.scope == f.scope else { return false }
            if case .progress(let p) = event.payload { return p.consumedSampleEnd == 9600 }; return false
        } })
        #expect(audit.returnedPredictions(.microphone) == 2 && audit.modelCount == 2)
        #expect(audit.lanes.filter { event in
            guard event.scope == f.scope else { return false }
            if case .vad(.degraded(_,let context,4096)) = event.payload { return context != nil }; return false
        }.count == 1)
        #expect(await helper.handle(.cut(scope: f.scope,nextPacketSequence: 3,sampleEnd: 9600,reason: .deviceInterruption),requestID: UUID()) == .accepted)
        let pauseID = UUID()
        #expect(await helper.handle(f.barrier(end: 9600,sequence: 3,kind: .pause),requestID: pauseID) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            if case .barrierCompleted(let id,.pause,9600) = event.payload { return id == pauseID }; return false
        } })
        let fresh = f.epoch(id: UUID()), scope = LiveLaneScope(identity: f.scope.identity,source: .microphone,epochID: fresh.id)
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: fresh),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            guard event.scope == scope else { return false }
            if case .ready = event.payload { return true }; return false
        } })
        let statuses = audit.lanes.filter { $0.scope == scope }.compactMap { event -> LiveVADModuleEvent? in
            if case .vad(let value) = event.payload { return value }; return nil
        }
        try #require(statuses.count == 1)
        guard case .degraded(_,nil,0) = statuses[0] else { Issue.record("Failed source advertised new preparation/readiness"); return }
        #expect(try await helper.handle(f.packet(0,start: 0,scope: scope),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            guard event.scope == scope else { return false }
            if case .progress(let p) = event.payload { return p.consumedSampleEnd == 3200 && p.effectiveASRConsumedSampleEnd == 3200 }; return false
        } })
        for i in 0..<2 {
            #expect(try await helper.handle(f.packet(UInt64(i),start: Int64(i*2048),count: 2048,scope: f.systemScope),requestID: UUID()) == .accepted)
        }
        try #require(await pumpEventually { audit.lanes.contains { event in
            guard event.scope == f.systemScope else { return false }
            if case .vad(.processed(_,_,4096)) = event.payload { return true }; return false
        } })
        #expect(audit.predictions(.microphone) == 2 && audit.modelCount == 2)
    }

    @Test(arguments: [false,true],[false,true]) func terminalDuringPrivateInstallRejectsNewEpochWithoutPublication(cancel: Bool,afterMutation: Bool) async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit(), install = LifetimeSignal(), fresh = f.epoch(id: UUID())
        let helper = LiveASROrchestrator(loader: { _ in PumpFactory(audit: audit,finishGate: nil) },
            vadLoader: { input in try await f.load(input,a) },emit: audit.emit,
            testingBeforeInstall: { _,scope in
                if !afterMutation, scope.epochID == fresh.id { audit.installHeld(); await install.wait() }
            },
            testingAfterInstall: { _,scope in
                if afterMutation, scope.epochID == fresh.id { audit.installHeld(); await install.wait() }
            })
        defer { Task { await install.signal(); _ = await helper.handle(.cancel(f.scope.identity),requestID: UUID()) } }
        #expect(await helper.handle(.begin(f.begin(a)),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.ready })
        let pauseID = UUID()
        #expect(await helper.handle(f.barrier(end: 0,sequence: 0,kind: .pause),requestID: pauseID) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            if case .barrierCompleted(let id,.pause,0) = event.payload { return id == pauseID }; return false
        } })
        let attempt = Task { await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: fresh),requestID: UUID()) }
        try #require(await pumpEventually { audit.isInstallHeld })
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: f.epoch(id: UUID())),requestID: UUID()) == .rejected(.unavailable))
        if cancel { #expect(await helper.handle(.cancel(f.scope.identity),requestID: UUID()) == .accepted) }
        else { #expect(await helper.handle(f.barrier(end: 0,sequence: 0,kind: .finish),requestID: UUID()) == .accepted) }
        try #require(audit.terminal)
        let published = audit.lanes
        await install.signal()
        #expect(await attempt.value != .accepted)
        #expect(audit.lanes == published && !audit.lanes.contains { $0.scope.epochID == fresh.id })
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: fresh),requestID: UUID()) != .accepted)
    }

    @Test(arguments: [false,true]) func terminalCleanupRequiresNativeAndOriginalWorkReturnWithHealthyPeer(cutFirst: Bool) async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit(), prediction = LifetimeSignal(), tail = LifetimeSignal()
        let helper = LiveASROrchestrator(loader: { _ in PumpFactory(audit: audit,finishGate: nil) },
            vadLoader: { input in try await f.load(input,a,audit: audit,gate: prediction) },emit: audit.emit,
            testingBeforeWorkReturn: { scope in
                if scope == f.scope, audit.predictions(.microphone) > 0, !audit.isTailHeld {
                    audit.tailHeld(); await tail.wait()
                }
            },testingPacketDisposed: { scope in audit.packetDisposed(scope) })
        defer { Task {
            await prediction.signal(); await tail.signal()
            _ = await helper.handle(.cancel(f.scope.identity),requestID: UUID())
        } }
        #expect(await helper.handle(.begin(f.begin(a,both: true)),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.lanes.filter { if case .ready = $0.payload { true } else { false } }.count == 2 })
        #expect(try await helper.handle(f.packet(0,start: 0),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.disposals(.microphone) == 1 })
        #expect(try await helper.handle(f.packet(1,start: 3200),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.predictions(.microphone) == 1 })
        if cutFirst {
            #expect(await helper.handle(.cut(scope: f.scope,nextPacketSequence: 2,sampleEnd: 6400,reason: .deviceInterruption),requestID: UUID()) == .accepted)
        }
        let pauseID = UUID()
        #expect(await helper.handle(f.barrier(end: 6400,sequence: 2,kind: .pause),requestID: pauseID) == .accepted)
        func hasPauseACK() -> Bool { audit.lanes.contains { event in
            if case .barrierCompleted(let id,.pause,6400) = event.payload { return id == pauseID }; return false
        } }
        #expect(!hasPauseACK() && audit.returnedPredictions(.microphone) == 0 && audit.disposals(.microphone) == 1)
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: f.epoch(id: UUID())),requestID: UUID()) == .rejected(.unavailable))
        for i in 0..<2 {
            #expect(try await helper.handle(f.packet(UInt64(i),start: Int64(i*2048),count: 2048,scope: f.systemScope),requestID: UUID()) == .accepted)
        }
        try #require(await pumpEventually { audit.lanes.contains { event in
            guard event.scope == f.systemScope else { return false }
            if case .vad(.processed(_,_,4096)) = event.payload { return true }; return false
        } })
        #expect(!hasPauseACK())
        await prediction.signal()
        try #require(await pumpEventually { audit.isTailHeld })
        #expect(audit.returnedPredictions(.microphone) == 1 && audit.disposals(.microphone) == 1 && !hasPauseACK())
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: f.epoch(id: UUID())),requestID: UUID()) == .rejected(.unavailable))
        await tail.signal()
        try #require(await pumpEventually { hasPauseACK() && audit.disposals(.microphone) == 2 })
        let retired = audit.lanes.filter { event in
            guard event.scope == f.scope else { return false }
            if case .vad(.retired(_,_,cutFirst ? 0 : 4096)) = event.payload { return true }; return false
        }
        #expect(retired.count == 1 && audit.modelCount == 2)
        let fresh = f.epoch(id: UUID())
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: fresh),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            guard event.scope.epochID == fresh.id else { return false }
            if case .ready = event.payload { return true }; return false
        } })
        #expect(audit.modelCount == 2)
    }

    @Test(arguments: [LiveFinishBarrier.Kind.utterance,.pause,.finish])
    func equalExternalBoundaryCoalescesWithInternalFinishAndOriginalACK(kind: LiveFinishBarrier.Kind) async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit(), finish = LifetimeSignal()
        let helper = LiveASROrchestrator(loader: { _ in PumpFactory(audit: audit,finishGate: finish) },
            vadLoader: { input in try await f.load(input,a) },emit: audit.emit)
        defer { Task { await finish.signal(); _ = await helper.handle(.cancel(f.scope.identity),requestID: UUID()) } }
        #expect(await helper.handle(.begin(f.begin(a)),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.ready })
        for i in 0..<6 {
            #expect(try await helper.handle(f.packet(UInt64(i),start: Int64(i*3200),count: i == 5 ? 384 : 3200),requestID: UUID()) == .accepted)
        }
        try #require(await pumpEventually { audit.finishEnds == [16384] })
        let id = UUID(), barrier = f.barrier(end: 16384,sequence: 6,kind: kind)
        #expect(await helper.handle(barrier,requestID: id) == .accepted)
        #expect(await helper.handle(barrier,requestID: id) == .accepted)
        #expect(!audit.lanes.contains { if case .barrierCompleted = $0.payload { true } else { false } })
        await finish.signal()
        try #require(await pumpEventually { audit.lanes.contains { event in
            if case .barrierCompleted(let value,let receivedKind,16384) = event.payload { return value == id && receivedKind == kind }; return false
        } })
        #expect(await helper.handle(barrier,requestID: id) == .accepted)
        #expect(audit.finishEnds == [16384])
        #expect(audit.lanes.filter { if case .committed = $0.payload { true } else { false } }.count == 1)
        #expect(audit.lanes.filter { if case .barrierCompleted = $0.payload { true } else { false } }.count == 1)
        #expect(audit.decoderCount == (kind == .utterance ? 2 : 1))
        if kind == .pause {
            #expect(await helper.handle(f.barrier(end: 16384,sequence: 6,kind: .finish),requestID: UUID()) == .accepted)
            try #require(await pumpEventually { audit.terminal })
            #expect(audit.finishEnds == [16384] && audit.modules.filter { if case .retired = $0 { true } else { false } }.count == 1)
        }
    }

    @Test func externalFinishBeforeFirstVADWindowFlushesExactASRPrefix() async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit()
        let helper = LiveASROrchestrator(loader: { _ in PumpFactory(audit: audit,finishGate: nil) },
            vadLoader: { input in try await f.load(input,a,audit: audit) },emit: audit.emit)
        #expect(await helper.handle(.begin(f.begin(a)),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.ready })
        #expect(try await helper.handle(f.packet(0,start: 0,count: 896),requestID: UUID()) == .accepted)
        let id = UUID()
        #expect(await helper.handle(f.barrier(end: 896,sequence: 1,kind: .finish),requestID: id) == .accepted)
        try #require(await pumpEventually { audit.terminal })
        #expect(audit.finishEnds == [896] && audit.predictions(.microphone) == 0)
        #expect(audit.modules.filter { if case .processed = $0 { true } else { false } }.isEmpty)
        #expect(audit.lanes.contains { if case .barrierCompleted(let value,.finish,896) = $0.payload { value == id } else { false } })
    }

    @Test func globalCancelPreventsVADLoadAfterActualCancellationIgnoringASRReturn() async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit(), loading = LifetimeSignal()
        let helper = LiveASROrchestrator(loader: { _ in
                audit.asrLoadHeld(); await loading.wait(); return PumpFactory(audit: audit,finishGate: nil)
            },vadLoader: { _ in audit.vadLoadEntered(); throw LiveProtocolError.unavailable },emit: audit.emit,
            testingAfterLoadingReturn: audit.loadingReturned)
        defer { Task { await loading.signal(); _ = await helper.handle(.cancel(f.scope.identity),requestID: UUID()) } }
        #expect(await helper.handle(.begin(f.begin(a)),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.isASRLoadHeld })
        #expect(await helper.handle(.cancel(f.scope.identity),requestID: UUID()) == .accepted)
        try #require(audit.terminal)
        let published = audit.lanes
        await loading.signal()
        try #require(await pumpEventually { audit.hasLoadingReturned })
        #expect(audit.vadLoadCount == 0 && audit.decoderCount == 0)
        #expect(audit.lanes == published)
    }

    @Test func pausedInitialActivationClearsExactSetupDebtAndFreshEpochRecovers() async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit(), activation = LifetimeSignal()
        let helper = LiveASROrchestrator(loader: { _ in PumpFactory(audit: audit,finishGate: nil) },
            vadLoader: { input in try await f.load(input,a) },emit: audit.emit,
            testingBeforeVADActivation: { scope in
                if scope == f.scope { audit.activationHeld(); await activation.wait() }
            })
        defer { Task { await activation.signal(); _ = await helper.handle(.cancel(f.scope.identity),requestID: UUID()) } }
        #expect(await helper.handle(.begin(f.begin(a,both: true)),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.isActivationHeld })
        let id = UUID()
        #expect(await helper.handle(f.barrier(end: 0,sequence: 0,kind: .pause),requestID: id) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            if case .barrierCompleted(let value,.pause,0) = event.payload { return value == id }; return false
        } })
        #expect(await helper.handle(f.barrier(end: 0,sequence: 0,kind: .pause),requestID: id) == .accepted)
        let retiredEvents = audit.lanes.filter { $0.scope == f.scope }
        let premature = f.epoch(id: UUID())
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: premature),requestID: UUID()) == .rejected(.unavailable))
        await activation.signal()
        try #require(await pumpEventually { audit.lanes.contains { event in
            guard event.scope == f.systemScope else { return false }
            if case .ready = event.payload { return true }; return false
        } })
        #expect(audit.lanes.filter { $0.scope == f.scope } == retiredEvents)
        let fresh = f.epoch(id: UUID())
        try #require(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: fresh),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            guard event.scope.epochID == fresh.id else { return false }
            if case .ready = event.payload { return true }; return false
        } })
        #expect(try await helper.handle(f.packet(0,start: 0,scope: f.systemScope),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.appends.contains { $0.total == 3200 } })
    }

    @Test func unboundZeroInputPeerFinishesWhileAnotherSourceActivationIsHeld() async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit(), activation = LifetimeSignal()
        let helper = LiveASROrchestrator(loader: { _ in PumpFactory(audit: audit,finishGate: nil) },
            vadLoader: { input in try await f.load(input,a) },emit: audit.emit,
            testingBeforeVADActivation: { scope in
                if scope == f.scope { audit.activationHeld(); await activation.wait() }
            })
        defer { Task { await activation.signal(); _ = await helper.handle(.cancel(f.scope.identity),requestID: UUID()) } }
        #expect(await helper.handle(.begin(f.begin(a,both: true)),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.isActivationHeld })
        let id = UUID()
        #expect(await helper.handle(f.barrier(end: 0,sequence: 0,kind: .finish,scope: f.systemScope),requestID: id) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            guard event.scope == f.systemScope else { return false }
            if case .barrierCompleted(let value,.finish,0) = event.payload { return value == id }; return false
        } })
        #expect(!audit.terminal && audit.decoderCount == 0)
        #expect(!audit.lanes.contains { event in
            guard event.scope == f.systemScope else { return false }
            if case .ready = event.payload { return true }; return false
        })
        await activation.signal()
        try #require(await pumpEventually { audit.ready })
    }

    @Test(arguments: [560,1120,2240]) func configuredPacketsBisectAtActualWindowsAndOriginalTailKeepsUnionCredit(chunkMs: Int) async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit(), tail = LifetimeSignal()
        defer { Task { await tail.signal() } }
        let helper = LiveASROrchestrator(loader: { _ in PumpFactory(audit: audit,finishGate: nil) },
            vadLoader: { input in try await f.load(input,a,audit: audit) },emit: audit.emit,
            testingBeforeWorkReturn: { _ in
                if audit.appends.reduce(0,{ $0+$1.count }) == 6400 { audit.tailHeld(); await tail.wait() }
            },testingPacketDisposed: { _ in audit.packetDisposed() })
        let input = f.begin(a,chunkMs: chunkMs)
        #expect(await helper.handle(.begin(input),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.ready })
        #expect(audit.modules.count == 2)
        guard case .preparing? = audit.modules.first, case .ready? = audit.modules.last else { Issue.record("Missing ordered VAD preparation/ready"); return }
        #expect(try await helper.handle(f.packet(0,start: 0,value: 0.25),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.disposedCount == 1 })
        #expect(try await helper.handle(f.packet(1,start: 3200,value: 0.75),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.isTailHeld })
        #expect(audit.appends.map(\.count) == [3200,896,2304])
        #expect(audit.appends.map(\.checksum) == [800,672,1728] && audit.checksums(.microphone) == [1472])
        #expect(audit.disposedCount == 1)
        #expect(audit.progresses.last?.consumedSampleEnd == 3200)
        #expect(audit.progresses.last?.inFlightSamples == 3200)
        #expect(audit.progresses.last?.effectiveASRConsumedSampleEnd == 6400)
        #expect(audit.progresses.last?.creditSamples == Int64(input.configuration.pendingSampleLimit)-3200)
        #expect(audit.lanes.filter { if case .admitted = $0.payload { true } else { false } }.count == 2)
        await tail.signal()
        try #require(await pumpEventually { audit.disposedCount == 2 && audit.progresses.last?.consumedSampleEnd == 4096 })
        let id = UUID()
        #expect(await helper.handle(f.barrier(end: 6400,sequence: 2,kind: .finish),requestID: id) == .accepted)
        try #require(await pumpEventually { audit.terminal })
        #expect(audit.finishEnds == [6400])
        #expect(audit.modules.filter { if case .retired = $0 { true } else { false } }.count == 1)
        #expect(audit.lanes.contains { if case .barrierCompleted(let received,.finish,6400) = $0.payload { received == id } else { false } })
    }

    @Test func VADFinishAndFreshASRPreparationPrecedeTheFutureOriginalSuffix() async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit(), finish = LifetimeSignal(); defer { Task { await finish.signal() } }
        let helper = LiveASROrchestrator(loader: { _ in PumpFactory(audit: audit,finishGate: finish) },
            vadLoader: { input in try await f.load(input,a) },emit: audit.emit)
        #expect(await helper.handle(.begin(f.begin(a)),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.ready })
        for index in 0..<6 {
            #expect(try await helper.handle(f.packet(UInt64(index),start: Int64(index*3200)),requestID: UUID()) == .accepted)
        }
        try #require(await pumpEventually { audit.finishEnds == [16384] })
        #expect(audit.decoderCount == 1 && audit.appends.reduce(0,{ $0+$1.count }) == 16384)
        #expect(audit.lanes.compactMap { if case .partial(let p) = $0.payload { p.samples.end } else { nil } }.allSatisfy { $0 <= 16384 })
        await finish.signal()
        try #require(await pumpEventually { audit.appends.reduce(0,{ $0+$1.count }) == 19200 })
        #expect(audit.decoderCount == 2)
        #expect(audit.appends.last?.decoder == 2 && audit.appends.last?.count == 2816)
        #expect(audit.lanes.contains { if case .committed(let value) = $0.payload { value.range.samples?.end == 16384 } else { false } })
        let contexts = audit.modules.compactMap { if case .processed(_,let context,_) = $0 { context } else { nil } }
        #expect(contexts.count == 4 && Set(contexts).count == 1)
        #expect(await helper.handle(f.barrier(end: 19200,sequence: 6,kind: .finish),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.terminal })
        #expect(audit.finishEnds == [16384,2816])
    }

    @Test func loadingZeroInputFinishAcknowledgesWithoutWaitingForLateModelSetup() async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit(), loading = LifetimeSignal(); defer { Task { await loading.signal() } }
        let helper = LiveASROrchestrator(loader: { _ in PumpFactory(audit: audit,finishGate: nil) },
            vadLoader: { input in audit.vadLoadEntered(); await loading.wait(); return try await f.load(input,a) },emit: audit.emit,
            testingAfterLoadingReturn: audit.loadingReturned)
        #expect(await helper.handle(.begin(f.begin(a)),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.vadLoadCount == 1 })
        let id = UUID()
        #expect(await helper.handle(f.barrier(end: 0,sequence: 0,kind: .finish),requestID: id) == .accepted)
        try #require(await pumpEventually { audit.terminal })
        #expect(!audit.ready && audit.decoderCount == 0)
        #expect(audit.lanes.contains { if case .barrierCompleted(let value,.finish,0) = $0.payload { value == id } else { false } })
        let published = audit.lanes
        await loading.signal()
        try #require(await pumpEventually { audit.hasLoadingReturned })
        #expect(await helper.handle(.cancel(f.scope.identity),requestID: UUID()) == .accepted)
        #expect(audit.lanes == published)
    }

    @Test(arguments: [false,true]) func canceledPrivateInstallRejectsWithoutEventsAndAllowsFreshRetryAfterActualAbort(afterMutation: Bool) async throws {
        let f = PumpFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let audit = PumpAudit(), install = LifetimeSignal(), canceledEpoch = f.epoch(id: UUID())
        defer { Task { await install.signal() } }
        let helper = LiveASROrchestrator(loader: { _ in PumpFactory(audit: audit,finishGate: nil) },
            vadLoader: { input in try await f.load(input,a) },emit: audit.emit,
            testingBeforeInstall: { _,newScope in
                if !afterMutation, newScope.epochID == canceledEpoch.id { audit.installHeld(); await install.wait() }
            },
            testingAfterInstall: { _,newScope in
                if afterMutation, newScope.epochID == canceledEpoch.id { audit.installHeld(); await install.wait() }
            })
        #expect(await helper.handle(.begin(f.begin(a)),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.ready })
        let pauseID = UUID()
        #expect(await helper.handle(f.barrier(end: 0,sequence: 0,kind: .pause),requestID: pauseID) == .accepted)
        try #require(await pumpEventually {
            audit.lanes.contains { if case .barrierCompleted(let id,.pause,0) = $0.payload { id == pauseID } else { false } }
        })
        let attempt = Task { await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: canceledEpoch),requestID: UUID()) }
        try #require(await pumpEventually { audit.isInstallHeld })
        #expect(await helper.handle(.cut(scope: f.scope,nextPacketSequence: 1,sampleEnd: 3200,reason: .deviceInterruption),requestID: UUID()) == .accepted)
        #expect(try await helper.handle(f.packet(1,start: 3200),requestID: UUID()) == .rejected(.unavailable))
        attempt.cancel(); await install.signal()
        #expect(await attempt.value != .accepted)
        #expect(!audit.lanes.contains { $0.scope.epochID == canceledEpoch.id })
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: canceledEpoch),requestID: UUID()) == .rejected(.invalidConfiguration))
        let fresh = f.epoch(id: UUID())
        #expect(await helper.handle(.replaceEpoch(identity: f.scope.identity,oldEpochID: f.scope.epochID,epoch: fresh),requestID: UUID()) == .accepted)
        try #require(await pumpEventually { audit.lanes.contains { event in
            guard event.scope.epochID == fresh.id else { return false }
            if case .ready = event.payload { return true }; return false
        } })
        #expect(await helper.handle(.cancel(f.scope.identity),requestID: UUID()) == .accepted)
    }
}
