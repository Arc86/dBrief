import Foundation
import Testing
import dBriefWire
@testable import dBriefMLHost

private final class RuntimeAudit: @unchecked Sendable {
    private let lock = NSLock()
    private weak var mic: RuntimeHandle?
    private weak var system: RuntimeHandle?
    private var loads = 0, released = 0
    private var stored: [LiveSource: [LiveVADNativeInput]] = [:]
    private var commitHeld = false, outerReturned = false, receiptReturned = false
    private var resultHeld = false, failureEntered = false
    private weak var inputError: RuntimeInputError?
    private weak var originalPacket: RuntimePacketProbe?
    func register(_ handle: RuntimeHandle) { lock.withLock { if loads == 0 { mic = handle } else { system = handle }; loads += 1 } }
    var loadCount: Int { lock.withLock { loads } }
    var modelsAlive: Bool { lock.withLock { mic != nil && system != nil } }
    var releaseCount: Int { lock.withLock { released } }
    func release() { lock.withLock { released += 1 } }
    func call(_ source: LiveSource, _ input: LiveVADNativeInput) -> Int {
        lock.withLock { stored[source,default: []].append(input); return stored[source]!.count }
    }
    func inputs(_ source: LiveSource) -> [LiveVADNativeInput] { lock.withLock { stored[source] ?? [] } }
    func holdCommit() { lock.withLock { commitHeld = true } }
    var isCommitHeld: Bool { lock.withLock { commitHeld } }
    func returned() { lock.withLock { outerReturned = true } }
    var hasReturned: Bool { lock.withLock { outerReturned } }
    func receiptCompleted() { lock.withLock { receiptReturned = true } }
    var isReceiptCompleted: Bool { lock.withLock { receiptReturned } }
    func observe(_ error: RuntimeInputError) { lock.withLock { inputError = error; failureEntered = true } }
    var errorAlive: Bool { lock.withLock { inputError != nil } }
    var hasNativeFailure: Bool { lock.withLock { failureEntered } }
    func holdResult() { lock.withLock { resultHeld = true } }
    var isResultHeld: Bool { lock.withLock { resultHeld } }
    func observe(_ packet: RuntimePacketProbe) { lock.withLock { originalPacket = packet } }
    var originalAlive: Bool { lock.withLock { originalPacket != nil } }
}

private final class RuntimeInputError: Error, Sendable {
    let input: LiveVADNativeInput
    init(_ input: LiveVADNativeInput) { self.input = input }
}
private final class RuntimePacketProbe: Sendable {
    let samples = [Float](repeating: 1,count: 3200)
}
private func retainedOuterTask(packet: RuntimePacketProbe,runtime: LiveVADModuleRuntime,token: LiveVADRuntimeToken,audit: RuntimeAudit) -> Task<LiveVADRuntimeCompletion,Error> {
    Task {
        defer { withExtendedLifetime(packet) {}; audit.returned() }
        return try await runtime.complete(token)
    }
}

private final class RuntimeHandle: LiveVADModelHandle, Sendable {
    let assets: LiveVADModelAssets
    let source: LiveSource
    let audit: RuntimeAudit
    let gate: LifetimeSignal?
    let failAt: Int?
    init(assets: LiveVADModelAssets,source: LiveSource,audit: RuntimeAudit,gate: LifetimeSignal?,failAt: Int?) {
        self.assets = assets; self.source = source; self.audit = audit; self.gate = gate; self.failAt = failAt
    }
    func validate(_ contract: LiveVADModelContract) async throws { try contract.validate(VADLoadFixture.description) }
    func predict(_ input: LiveVADNativeInput) async throws -> LiveVADNativeOutput {
        let call = audit.call(source,input)
        await gate?.wait() // Deliberately ignores cancellation until real return.
        if call == failAt {
            let error = RuntimeInputError(input); audit.observe(error); throw error
        }
        return try .init(probability: call == 1 ? 1 : 0,
            hiddenState: [Float](repeating: Float(call),count: 128),cellState: [Float](repeating: -Float(call),count: 128))
    }
    deinit { audit.release() }
}

private struct RuntimeFixture: Sendable {
    let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
    let micID = UUID(), systemID = UUID()
    func scope(_ source: LiveSource = .microphone) -> LiveLaneScope {
        .init(identity: identity,source: source,epochID: source == .microphone ? micID : systemID)
    }
    func begin(_ vad: LiveVADConfiguration, both: Bool = true) -> LiveSessionBegin {
        .init(identity: identity,configuration: .init(language: .auto,modelDirectory: "/fixture/asr"),
            epochs: (both ? [LiveSource.microphone,.system] : [.microphone]).map {
                .init(id: scope($0).epochID,source: $0,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
            },vad: vad)
    }
    func runtime(_ f: VADLoadFixture,audit: RuntimeAudit,gate: LifetimeSignal? = nil,failAt: Int? = nil,
                 beforeCommit: @escaping @Sendable (LiveLaneScope) async -> Void = { _ in },
                 beforeResult: @escaping @Sendable (LiveLaneScope) async -> Void = { _ in }) async throws -> LiveVADModuleRuntime {
        let assets = try await f.assets()
        let pool = try await LiveVADModelFactory.load(configuration: f.configuration,sources: [.microphone,.system],assets: assets) { assets,_ in
            let source: LiveSource = audit.loadCount == 0 ? .microphone : .system
            let handle = RuntimeHandle(assets: assets,source: source,audit: audit,gate: source == .microphone ? gate : nil,failAt: source == .microphone ? failAt : nil)
            audit.register(handle); return handle
        }
        return try LiveVADModuleRuntime(input: begin(f.configuration),factory: pool,testingBeforeCommit: beforeCommit,testingBeforeResult: beforeResult)
    }
    func token(_ runtime: LiveVADModuleRuntime,scope: LiveLaneScope? = nil,start: Int64 = 0,value: Float = 1) async throws -> LiveVADRuntimeToken {
        let scope = scope ?? self.scope()
        _ = try await runtime.admitSlice(scope: scope,samples: [Float](repeating: value,count: 3200),startSample: start)
        let result = try await runtime.admitSlice(scope: scope,samples: [Float](repeating: value,count: 896),startSample: start+3200)
        guard case .window(let token) = result else { throw LiveProtocolError.unavailable }
        return token
    }
}

private func runtimeEventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<500 { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(2)) }
    return false
}

@Suite struct LiveVADRuntimeTests {
    @Test func boundedSlicesProduceExactWindowsAndKeepPeerStateIndependent() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let fixture = RuntimeFixture(), audit = RuntimeAudit(), runtime = try await fixture.runtime(f,audit: audit)
        let scope = fixture.scope()
        let ready = try await runtime.activate(scope: scope)
        guard case .ready(let identity,let context,let origin) = ready else { Issue.record("missing ready"); return }
        #expect(identity == f.configuration.identity && origin == 0)
        #expect(try await runtime.sliceCapacity(scope: scope) == 3200)
        _ = try await runtime.admitSlice(scope: scope,samples: (0..<3200).map(Float.init),startSample: 0)
        #expect(try await runtime.sliceCapacity(scope: scope) == 896)
        _ = try await runtime.admitSlice(scope: scope,samples: (3200..<4095).map(Float.init),startSample: 3200)
        #expect(try await runtime.progress(scope: scope).remainderSamples == 4095)
        #expect(try await runtime.sliceCapacity(scope: scope) == 1)
        let admitted = try await runtime.admitSlice(scope: scope,samples: [4095],startSample: 4095)
        guard case .window(let token) = admitted else { Issue.record("missing window"); return }
        #expect(try await runtime.sliceCapacity(scope: scope) == 0)
        let complete = try await runtime.complete(token)
        guard case .processed(let event,let decision) = complete else { Issue.record("missing result"); return }
        #expect(event == .processed(identity: identity,contextID: context,sampleEnd: 4096))
        #expect(decision.range == .init(start: 0,end: 4096) && decision.flushEnd == nil)
        #expect(audit.inputs(.microphone)[0].audio == [Float](repeating: 0,count: 64)+(0..<4096).map(Float.init))
        for end: Int64 in [8192,12288,16384] {
            let token = try await fixture.token(runtime,start: end-4096,value: -2)
            guard case .processed(_,let decision) = try await runtime.complete(token) else { Issue.record("missing later result"); return }
            #expect(decision.flushEnd == (end == 16384 ? end : nil))
        }
        #expect(audit.inputs(.microphone)[1].audio.prefix(64) == (4032..<4096).map(Float.init)[...])
        #expect(audit.inputs(.microphone)[1].hiddenState == [Float](repeating: 1,count: 128))
        #expect(try await runtime.progress(scope: fixture.scope(.system)).phase == .unknown)
        #expect(try await runtime.progress(scope: scope).processedEnd == 16384)
    }

    @Test func malformedAdmissionNeverPredictsOrChangesEitherSource() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let fixture = RuntimeFixture(), audit = RuntimeAudit(), runtime = try await fixture.runtime(f,audit: audit)
        let scope = fixture.scope(); _ = try await runtime.activate(scope: scope)
        _ = try await runtime.admitSlice(scope: scope,samples: [Float](repeating: 1,count: 3200),startSample: 0)
        let before = try await runtime.progress(scope: scope)
        for (samples,start): ([Float],Int64) in [([],3200),([1],3199),([1],3201),([.nan],3200),([.infinity],3200),
            ([Float](repeating: 0,count: 897),3200),([Float](repeating: 0,count: 3201),3200),([1],.max),([1],.min)] {
            await #expect(throws: LiveVADRuntimeError.invalidSlice) { try await runtime.admitSlice(scope: scope,samples: samples,startSample: start) }
            #expect(try await runtime.progress(scope: scope) == before)
        }
        let foreign = LiveLaneScope(identity: fixture.identity,source: .system,epochID: fixture.micID)
        await #expect(throws: LiveProtocolError.staleScope) { try await runtime.admitSlice(scope: foreign,samples: [1],startSample: 0) }
        #expect(audit.inputs(.microphone).isEmpty && audit.inputs(.system).isEmpty)
    }

    @Test func nativeFailureKeepsPoolAndLastSuccessfulFrontierAcrossFreshScope() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let fixture = RuntimeFixture(), audit = RuntimeAudit(), runtime = try await fixture.runtime(f,audit: audit,failAt: 2)
        let scope = fixture.scope(); _ = try await runtime.activate(scope: scope)
        _ = try await runtime.complete(fixture.token(runtime))
        let token = try await fixture.token(runtime,start: 4096)
        guard case .degraded(let event,let receipt) = try await runtime.complete(token) else { Issue.record("missing degraded"); return }
        let progress = try await runtime.progress(scope: scope)
        #expect(event == .degraded(identity: f.configuration.identity,contextID: progress.contextID,sampleEnd: 4096))
        #expect(progress.phase == .degraded && progress.nativeFailureSeen && progress.modelReadySeen && progress.remainderSamples == 0)
        let cut = try await runtime.retireInput(scope: scope)
        #expect(cut.firstSeal && cut.receipt === receipt)
        try await runtime.settleRetirement(receipt)
        try await runtime.settleRetirement(cut.receipt) // Same phase/cut is idempotent.
        let fresh = LiveLaneScope(identity: fixture.identity,source: .microphone,epochID: UUID())
        try await runtime.installAfterRetirement(oldScope: scope,newScope: fresh)
        #expect(try await runtime.activate(scope: fresh) == .degraded(identity: f.configuration.identity,contextID: nil,sampleEnd: 0))
        #expect(try await runtime.progress(scope: fresh).nativeFailureSeen)
        #expect(audit.modelsAlive && audit.loadCount == 2 && audit.inputs(.microphone).count == 2)
        await #expect(throws: LiveVADRuntimeError.inactive) { try await runtime.admitSlice(scope: fresh,samples: [1],startSample: 0) }
    }

    @Test func heldNativeRetirementCoalescesAndCancelledWaiterCannotCancelCleanup() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let fixture = RuntimeFixture(), audit = RuntimeAudit(), gate = LifetimeSignal()
        let runtime = try await fixture.runtime(f,audit: audit,gate: gate)
        defer { Task { await gate.signal() } }
        let scope = fixture.scope(); _ = try await runtime.activate(scope: scope)
        let token = try await fixture.token(runtime)
        let completion = Task { try await runtime.complete(token) }
        try #require(await runtimeEventually { audit.inputs(.microphone).count == 1 })
        let a = try await runtime.retireInput(scope: scope), b = try await runtime.retireInput(scope: scope)
        #expect(a.firstSeal && !b.firstSeal && a.receipt === b.receipt)
        let waiter = Task { try await runtime.settleRetirement(a.receipt); audit.receiptCompleted() }
        waiter.cancel()
        let fresh = LiveLaneScope(identity: fixture.identity,source: .microphone,epochID: UUID())
        await #expect(throws: LiveProtocolError.unavailable) { try await runtime.installAfterRetirement(oldScope: scope,newScope: fresh) }
        #expect(!audit.isReceiptCompleted && audit.modelsAlive)
        _ = try await runtime.activate(scope: fixture.scope(.system))
        _ = try await runtime.complete(fixture.token(runtime,scope: fixture.scope(.system)))
        await gate.signal()
        try await waiter.value
        await #expect(throws: LiveVADRuntimeError.inactive) { try await completion.value }
        #expect(try await runtime.progress(scope: scope).inputRetired)
        #expect(try await runtime.progress(scope: scope).nativeFailureSeen == false)
        try await runtime.settleRetirement(b.receipt)
        try await runtime.installAfterRetirement(oldScope: scope,newScope: fresh)
        #expect(audit.modelsAlive)
    }

    @Test func cancellationAfterPrivateSuccessSealsWithoutPoisoningAndReceiptExcludesOuterTask() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let fixture = RuntimeFixture(), audit = RuntimeAudit(), commitGate = LifetimeSignal()
        let runtime = try await fixture.runtime(f,audit: audit,beforeCommit: { scope in
            if scope == fixture.scope() { audit.holdCommit(); await commitGate.wait() }
        })
        defer { Task { await commitGate.signal() } }
        let scope = fixture.scope(), ready = try await runtime.activate(scope: scope)
        let token = try await fixture.token(runtime)
        var packet: RuntimePacketProbe? = .init()
        audit.observe(try #require(packet))
        let outer = retainedOuterTask(packet: try #require(packet),runtime: runtime,token: token,audit: audit)
        packet = nil
        try #require(await runtimeEventually { audit.isCommitHeld })
        #expect(try await runtime.progress(scope: scope).processedEnd == 0)
        outer.cancel()
        try #require(await runtimeEventually { (try? await runtime.progress(scope: scope).phase) == .retired })
        let seal = try await runtime.retireInput(scope: scope)
        try await runtime.settleRetirement(seal.receipt)
        #expect(!audit.hasReturned) // VAD-only proof cannot retire original packet/outer Work.
        #expect(audit.originalAlive)
        #expect(try await runtime.progress(scope: scope).inputRetired)
        #expect(try await runtime.progress(scope: scope).nativeFailureSeen == false)
        let fresh = LiveLaneScope(identity: fixture.identity,source: .microphone,epochID: UUID())
        try await runtime.installAfterRetirement(oldScope: scope,newScope: fresh)
        let freshReady = try await runtime.activate(scope: fresh)
        #expect(freshReady != ready)
        await commitGate.signal()
        await #expect(throws: CancellationError.self) { try await outer.value }
        #expect(await runtimeEventually { !audit.originalAlive })
        #expect(try await runtime.progress(scope: fresh).phase == .active)
        #expect(try await runtime.progress(scope: fresh).processedEnd == 0)
        let newToken = try await fixture.token(runtime,scope: fresh)
        _ = try await runtime.complete(newToken)
        #expect(audit.inputs(.microphone)[1].hiddenState == [Float](repeating: 0,count: 128))
        #expect(audit.inputs(.microphone)[1].audio.prefix(64) == [Float](repeating: 0,count: 64)[...])
    }

    @Test func callerCancellationWhileNativeIsHeldSealsWithoutClaimingActualReturn() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let fixture = RuntimeFixture(), audit = RuntimeAudit(), gate = LifetimeSignal()
        let runtime = try await fixture.runtime(f,audit: audit,gate: gate)
        defer { Task { await gate.signal() } }
        let scope = fixture.scope(); _ = try await runtime.activate(scope: scope)
        let token = try await fixture.token(runtime)
        let outer = Task { defer { audit.returned() }; return try await runtime.complete(token) }
        try #require(await runtimeEventually { audit.inputs(.microphone).count == 1 })
        try #require(await runtimeEventually { (try? await runtime.progress(scope: scope).completionClaimed) == true })
        outer.cancel()
        try #require(await runtimeEventually { (try? await runtime.progress(scope: scope).phase) == .retired })
        let seal = try await runtime.retireInput(scope: scope)
        #expect(!seal.firstSeal && !audit.hasReturned)
        #expect(try await runtime.progress(scope: scope).hasWork)
        #expect(try await runtime.progress(scope: scope).inputRetired == false)
        let settle = Task { try await runtime.settleRetirement(seal.receipt); audit.receiptCompleted() }
        let fresh = LiveLaneScope(identity: fixture.identity,source: .microphone,epochID: UUID())
        await #expect(throws: LiveProtocolError.unavailable) { try await runtime.installAfterRetirement(oldScope: scope,newScope: fresh) }
        #expect(!audit.isReceiptCompleted)
        await gate.signal()
        await #expect(throws: CancellationError.self) { try await outer.value }
        try await settle.value
        #expect(try await runtime.progress(scope: scope).nativeFailureSeen == false)
        try await runtime.installAfterRetirement(oldScope: scope,newScope: fresh)
        _ = try await runtime.activate(scope: fresh)
        let before = try await runtime.progress(scope: fresh)
        await #expect(throws: LiveProtocolError.staleScope) { try await runtime.settleRetirement(seal.receipt) }
        #expect(try await runtime.progress(scope: fresh) == before)
    }

    @Test func entryCancelledReservedCompletionSealsButStaleTokenCannotTouchFreshWork() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let fixture = RuntimeFixture(), audit = RuntimeAudit(), runtime = try await fixture.runtime(f,audit: audit)
        let scope = fixture.scope(); _ = try await runtime.activate(scope: scope)
        let token = try await fixture.token(runtime), enter = LifetimeSignal()
        let canceled = Task { await enter.wait(); return try await runtime.complete(token) }
        canceled.cancel(); await enter.signal()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        let seal = try await runtime.retireInput(scope: scope)
        #expect(!seal.firstSeal)
        try await runtime.settleRetirement(seal.receipt)
        let fresh = LiveLaneScope(identity: fixture.identity,source: .microphone,epochID: UUID())
        try await runtime.installAfterRetirement(oldScope: scope,newScope: fresh); _ = try await runtime.activate(scope: fresh)
        let staleEnter = LifetimeSignal(), stale = Task { await staleEnter.wait(); return try await runtime.complete(token) }
        stale.cancel(); await staleEnter.signal()
        await #expect(throws: LiveProtocolError.staleScope) { try await stale.value }
        #expect(try await runtime.progress(scope: fresh).phase == .active)
    }

    @Test func arbitraryNativeInputOwningErrorDiesBeforeReceiptWhileOuterWaitRemainsHeld() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let fixture = RuntimeFixture(), audit = RuntimeAudit(), resultGate = LifetimeSignal()
        let runtime = try await fixture.runtime(f,audit: audit,failAt: 1,beforeResult: { _ in audit.holdResult(); await resultGate.wait() })
        defer { Task { await resultGate.signal() } }
        let scope = fixture.scope(); _ = try await runtime.activate(scope: scope)
        let token = try await fixture.token(runtime), outer = Task { try await runtime.complete(token) }
        try #require(await runtimeEventually { audit.isResultHeld && audit.hasNativeFailure })
        let seal = try await runtime.retireInput(scope: scope)
        try await runtime.settleRetirement(seal.receipt)
        #expect(try await runtime.progress(scope: scope).inputRetired)
        #expect(!audit.errorAlive)
        await resultGate.signal()
        await #expect(throws: LiveVADRuntimeError.inactive) { try await outer.value }
    }

    @Test func duplicateCompletionClaimAndLateTokenNeverClearCurrentReservation() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let fixture = RuntimeFixture(), audit = RuntimeAudit(), commitGate = LifetimeSignal()
        let runtime = try await fixture.runtime(f,audit: audit,beforeCommit: { _ in audit.holdCommit(); await commitGate.wait() })
        defer { Task { await commitGate.signal() } }
        let scope = fixture.scope(); _ = try await runtime.activate(scope: scope)
        let token = try await fixture.token(runtime), first = Task { try await runtime.complete(token) }
        try #require(await runtimeEventually { audit.isCommitHeld })
        await #expect(throws: LiveProtocolError.outOfOrder) { try await runtime.complete(token) }
        await #expect(throws: LiveVADRuntimeError.overlap) { try await runtime.admitSlice(scope: scope,samples: [1],startSample: 4096) }
        await commitGate.signal(); _ = try await first.value
        let next = try await fixture.token(runtime,start: 4096)
        await #expect(throws: LiveProtocolError.outOfOrder) { try await runtime.complete(token) }
        #expect(try await runtime.progress(scope: scope).hasWork)
        _ = try await runtime.complete(next)
    }

    @Test func idleRemainderIsDisposedButModelsStayUntilOwnerDies() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let fixture = RuntimeFixture(), audit = RuntimeAudit()
        var owner: LiveVADModuleRuntime? = try await fixture.runtime(f,audit: audit)
        do {
            let runtime = try #require(owner), scope = fixture.scope()
            _ = try await runtime.activate(scope: scope)
            _ = try await runtime.admitSlice(scope: scope,samples: [Float](repeating: 1,count: 3200),startSample: 0)
            let seal = try await runtime.retireInput(scope: scope)
            try await runtime.settleRetirement(seal.receipt)
            #expect(try await runtime.progress(scope: scope).remainderSamples == 0)
            #expect(try await runtime.progress(scope: scope).inputRetired && audit.modelsAlive)
        }
        owner = nil
        #expect(await runtimeEventually { audit.releaseCount == 2 })
    }

    @Test func droppedExternalOwnerKeepsWholePoolThroughActualNativeReturn() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let fixture = RuntimeFixture(), audit = RuntimeAudit(), gate = LifetimeSignal()
        var owner: LiveVADModuleRuntime? = try await fixture.runtime(f,audit: audit,gate: gate)
        defer { Task { await gate.signal() } }
        do {
            let runtime = try #require(owner); _ = try await runtime.activate(scope: fixture.scope())
            _ = try await fixture.token(runtime)
        }
        try #require(await runtimeEventually { audit.inputs(.microphone).count == 1 })
        owner = nil
        #expect(audit.modelsAlive && audit.releaseCount == 0)
        await gate.signal()
        #expect(await runtimeEventually { audit.releaseCount == 2 })
    }

    @Test func preparationFallbackHasNoReadinessAndInvalidOwnershipCannotLoadAnotherPool() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let fixture = RuntimeFixture()
        let fallback = try LiveVADModuleRuntime(input: fixture.begin(f.configuration),factory: nil)
        #expect(try await fallback.activate(scope: fixture.scope()) == .degraded(identity: f.configuration.identity,contextID: nil,sampleEnd: 0))
        #expect(try await fallback.progress(scope: fixture.scope()).modelReadySeen == false)
        let seal = try await fallback.retireInput(scope: fixture.scope())
        try await fallback.settleRetirement(seal.receipt)
        let next = LiveLaneScope(identity: fixture.identity,source: .microphone,epochID: UUID())
        try await fallback.installAfterRetirement(oldScope: fixture.scope(),newScope: next)
        #expect(try await fallback.activate(scope: next) == .degraded(identity: f.configuration.identity,contextID: nil,sampleEnd: 0))
        let assets = try await f.assets(), audit = RuntimeAudit()
        let pool = try await LiveVADModelFactory.load(configuration: f.configuration,sources: [.microphone],assets: assets) { assets,_ in
            RuntimeHandle(assets: assets,source: .microphone,audit: audit,gate: nil,failAt: nil)
        }
        #expect(throws: LiveProtocolError.invalidConfiguration) { try LiveVADModuleRuntime(input: fixture.begin(f.configuration),factory: pool) }
        let wrong = LiveVADConfiguration(identity: f.configuration.identity,modelPath: "/foreign/model.mlmodelc")
        #expect(throws: LiveProtocolError.invalidConfiguration) { try LiveVADModuleRuntime(input: fixture.begin(wrong,both: false),factory: pool) }
    }
}
