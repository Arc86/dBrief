import Foundation
import Testing
import dBriefWire
@testable import dBriefMLHost

private struct SharedInputFixture: Sendable {
    let scope = LiveLaneScope(identity: .init(recordingID: UUID(),captureSessionID: UUID()),source: .microphone,epochID: UUID())
    let configuration = LiveASRConfiguration(language: .auto,chunkMs: 560,modelDirectory: "/fixture/asr")
    func begin(_ vad: LiveVADConfiguration) -> LiveSessionBegin {
        .init(identity: scope.identity,configuration: configuration,
            epochs: [.init(id: scope.epochID,source: scope.source,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)],vad: vad)
    }
    func ledger(owner: UUID = UUID()) throws -> LiveSharedInputLedger {
        try .init(scope: scope,configuration: configuration,vadOwnerID: owner)
    }
    func admit(_ ledger: inout LiveSharedInputLedger,start: Int64,count: Int = 3200) throws -> LiveSharedPacketReceipt {
        try ledger.admit(scope: scope,startSample: start,sampleCount: count)
    }
    func start(_ ledger: inout LiveSharedInputLedger,_ receipt: LiveSharedPacketReceipt) throws -> LiveSharedPacketToken {
        try ledger.startPacket(receipt,startSample: receipt.startSample,sampleCount: Int(receipt.sampleEnd-receipt.startSample))
    }
    func packet(_ ledger: inout LiveSharedInputLedger,start: Int64,count: Int = 3200) throws -> LiveSharedPacketToken {
        let receipt = try admit(&ledger,start: start,count: count)
        return try self.start(&ledger,receipt)
    }
    func append(_ ledger: inout LiveSharedInputLedger,_ token: LiveSharedPacketToken,_ range: Range<Int64>,consumed: Int64) throws {
        try ledger.submitSlice(token,range: range)
        try ledger.recordASRAppend(token,processedEnd: range.upperBound,consumedEnd: consumed)
    }
}

private final class SharedProofHandle: LiveVADModelHandle, Sendable {
    let assets: LiveVADModelAssets
    init(_ assets: LiveVADModelAssets) { self.assets = assets }
    func validate(_ contract: LiveVADModelContract) async throws { try contract.validate(VADLoadFixture.description) }
    func predict(_ input: LiveVADNativeInput) async throws -> LiveVADNativeOutput {
        try .init(probability: 0,hiddenState: [Float](repeating: 0,count: 128),cellState: [Float](repeating: 0,count: 128))
    }
}
private final class SharedOriginalPacket: Sendable { let samples = [Float](repeating: 1,count: 3200) }
private final class SharedNativeFailureAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    func entered() { lock.withLock { held = true } }
    var isHeld: Bool { lock.withLock { held } }
}
private actor SharedFailingHandle: LiveVADModelHandle {
    enum Failure: Error { case native }
    nonisolated let assets: LiveVADModelAssets
    private let audit: SharedNativeFailureAudit
    private let release: LifetimeSignal
    private var calls = 0
    init(_ assets: LiveVADModelAssets,audit: SharedNativeFailureAudit,release: LifetimeSignal) {
        self.assets = assets; self.audit = audit; self.release = release
    }
    func validate(_ contract: LiveVADModelContract) throws { try contract.validate(VADLoadFixture.description) }
    func predict(_ input: LiveVADNativeInput) async throws -> LiveVADNativeOutput {
        calls += 1
        if calls == 2 { audit.entered(); await release.wait(); throw Failure.native }
        return try .init(probability: 1,hiddenState: [Float](repeating: 0,count: 128),cellState: [Float](repeating: 0,count: 128))
    }
}
private final class SharedLifetimeAudit: @unchecked Sendable {
    private let lock = NSLock()
    private weak var packet: SharedOriginalPacket?
    func observe(_ value: SharedOriginalPacket) { lock.withLock { packet = value } }
    var alive: Bool { lock.withLock { packet != nil } }
}
private func sharedPacketTask(_ packet: SharedOriginalPacket,entered: LifetimeSignal,release: LifetimeSignal) -> Task<Void,Never> {
    Task { defer { withExtendedLifetime(packet) {} }; await entered.signal(); await release.wait() }
}

@Suite struct LiveSharedInputTests {
    @Test func originalPacketReturnAndBothConsumersIndependentlyGateUnionCredit() throws {
        let f = SharedInputFixture(); var ledger = try f.ledger()
        let first = try f.admit(&ledger,start: 0), second = try f.admit(&ledger,start: 3200)
        let work = try f.start(&ledger,first)
        try f.append(&ledger,work,0..<3200,consumed: 3200)
        try ledger.recordActualPacketReturn(work)
        #expect(ledger.progress.consumedEnd == 0)
        #expect(ledger.progress.queuedSamples == 3200 && ledger.progress.heldSamples == 3200)
        let next = try f.start(&ledger,second)
        var cursor = LivePacketSliceCursor(token: next)
        let prefix = try cursor.nextRange(vadCapacity: 896)
        #expect(prefix == 3200..<4096)
        try ledger.submitSlice(next,range: prefix)
        #expect(ledger.progress.asrSubmittedEnd == 4096 && ledger.progress.asrAppendedEnd == 3200)
        let unresolved = ledger
        #expect(throws: LiveProtocolError.self) { try ledger.recordVADProcessed(next,sampleEnd: 4096) }
        #expect(throws: LiveProtocolError.self) { try ledger.recordASRFlush(scope: f.scope,sampleEnd: 4096) }
        #expect(throws: LiveProtocolError.self) { try ledger.submitSlice(next,range: 4096..<6400) }
        #expect(ledger == unresolved)
        try ledger.recordASRAppend(next,processedEnd: 4096,consumedEnd: 3200)
        try cursor.commit(prefix)
        try ledger.recordVADProcessed(next,sampleEnd: 4096)
        #expect(ledger.progress.consumedEnd == 3200) // ASR still holds the edge.
        try ledger.recordASRFlush(scope: f.scope,sampleEnd: 4096)
        #expect(ledger.progress.consumedEnd == 3200) // Original second packet still lives.
        #expect(ledger.progress.inFlightSamples == 3200 && ledger.progress.pendingSamples == 3200)
        let suffix = try cursor.nextRange(vadCapacity: 3200)
        #expect(suffix == 4096..<6400)
        try f.append(&ledger,next,suffix,consumed: 6400); try cursor.commit(suffix)
        #expect(cursor.isComplete && ledger.progress.consumedEnd == 3200)
        try ledger.recordActualPacketReturn(next)
        #expect(ledger.progress.consumedEnd == 4096)
        #expect(ledger.progress.inFlightSamples == 0 && ledger.progress.heldSamples == 2304)
        #expect(ledger.progress.pendingSamples == 2304)
    }

    @Test func exactOriginalAdmissionReceiptsRejectAlteredMergedForeignAndDuplicateRanges() throws {
        let f = SharedInputFixture(); var ledger = try f.ledger(), other = try f.ledger()
        let first = try f.admit(&ledger,start: 0), second = try f.admit(&ledger,start: 3200)
        let foreign = try f.admit(&other,start: 0)
        let before = ledger
        for (receipt,start,count) in [(first,Int64(0),896),(first,0,6400),(first,1,3200),(second,3200,3200),(foreign,0,3200)] {
            #expect(throws: LiveProtocolError.self) { try ledger.startPacket(receipt,startSample: start,sampleCount: count) }
            #expect(ledger == before)
        }
        let token = try f.start(&ledger,first), busy = ledger
        #expect(throws: LiveProtocolError.self) { try f.start(&ledger,second) }
        #expect(throws: LiveProtocolError.self) { try ledger.recordActualPacketReturn(token) }
        #expect(ledger == busy)
        try f.append(&ledger,token,0..<3200,consumed: 0); try ledger.recordActualPacketReturn(token)
        let returned = ledger
        #expect(throws: LiveProtocolError.self) { try f.start(&ledger,first) }
        #expect(throws: LiveProtocolError.self) { try ledger.recordActualPacketReturn(token) }
        #expect(ledger == returned)
    }

    @Test func incompleteVADWindowSurvivesOrdinaryASRFinishWithoutFuturePCM() throws {
        let f = SharedInputFixture(); var ledger = try f.ledger()
        let token = try f.packet(&ledger,start: 0)
        try f.append(&ledger,token,0..<3200,consumed: 0); try ledger.recordActualPacketReturn(token)
        try ledger.recordASRFlush(scope: f.scope,sampleEnd: 3200)
        #expect(ledger.progress.asrConsumedEnd == 3200 && ledger.progress.vadProcessedEnd == 0)
        #expect(ledger.progress.consumedEnd == 0 && ledger.progress.heldSamples == 3200)
        let before = ledger
        #expect(throws: LiveProtocolError.self) { try ledger.recordASRFlush(scope: f.scope,sampleEnd: 3200) }
        #expect(ledger == before)
        let next = try f.packet(&ledger,start: 3200)
        try f.append(&ledger,next,3200..<4096,consumed: 3200)
        try ledger.recordVADProcessed(next,sampleEnd: 4096)
        #expect(ledger.progress.consumedEnd == 3200)
    }

    @Test func unionLimitCountsOverlappingHeldInputOnceAndMetadataQueueIsBounded() throws {
        let f = SharedInputFixture(); var ledger = try f.ledger()
        for index in 0..<12 {
            let receipt = try f.admit(&ledger,start: Int64(index*3200))
            let token = try f.start(&ledger,receipt)
            try f.append(&ledger,token,Int64(index*3200)..<Int64((index+1)*3200),consumed: 0)
            try ledger.recordActualPacketReturn(token)
        }
        #expect(ledger.progress.pendingSamples == 38400)
        _ = try f.admit(&ledger,start: 38400,count: 2560)
        #expect(ledger.progress.pendingSamples == 40960)
        let full = ledger
        #expect(throws: LiveProtocolError.self) { try f.admit(&ledger,start: 40960,count: 1) }
        #expect(ledger == full)
        var tiny = try f.ledger()
        for index in 0..<64 { _ = try f.admit(&tiny,start: Int64(index),count: 1) }
        let queued = tiny
        #expect(throws: LiveProtocolError.self) { try f.admit(&tiny,start: 64,count: 1) }
        #expect(tiny == queued && tiny.progress.pendingSamples == 64)
    }

    @Test func malformedFrontiersAndSliceCursorRejectWithoutMutation() throws {
        let f = SharedInputFixture(); var ledger = try f.ledger()
        let origin = ledger
        for (start,count) in [(Int64(-1),1),(Int64.max,3200),(0,0),(0,3201),(1,100)] {
            #expect(throws: LiveProtocolError.self) { try f.admit(&ledger,start: start,count: count) }
            #expect(ledger == origin)
        }
        let token = try f.packet(&ledger,start: 0), before = ledger
        for range in [1..<100,0..<0,0..<3201] as [Range<Int64>] {
            #expect(throws: LiveProtocolError.self) { try ledger.submitSlice(token,range: range) }
            #expect(ledger == before)
        }
        try ledger.submitSlice(token,range: 0..<896)
        let pending = ledger
        for (end,consumed) in [(897,0),(896,-1),(896,897)] as [(Int64,Int64)] {
            #expect(throws: LiveProtocolError.self) { try ledger.recordASRAppend(token,processedEnd: end,consumedEnd: consumed) }
            #expect(ledger == pending)
        }
        try ledger.recordASRAppend(token,processedEnd: 896,consumedEnd: 0)
        let appended = ledger
        for end in [Int64(0),4095,4096,8192] {
            #expect(throws: LiveProtocolError.self) { try ledger.recordVADProcessed(token,sampleEnd: end) }
            #expect(ledger == appended)
        }
        var cursor = LivePacketSliceCursor(token: token)
        let initial = cursor
        for capacity in [0,-1,3201] {
            #expect(throws: LiveProtocolError.self) { try cursor.nextRange(vadCapacity: capacity) }
            #expect(cursor == initial)
        }
        #expect(throws: LiveProtocolError.self) { try cursor.commit(1..<896) }
        #expect(cursor == initial)
        let slice = try cursor.nextRange(vadCapacity: 896)
        try cursor.commit(slice)
        #expect(cursor.nextSample == 896)
    }

    @Test func submittedASRPrefixCannotBeMistakenForAppendedOrReleasedInput() throws {
        let f = SharedInputFixture(); var ledger = try f.ledger()
        let token = try f.packet(&ledger,start: 0)
        try ledger.submitSlice(token,range: 0..<3200)
        #expect(ledger.progress.asrSubmittedEnd == 3200 && ledger.progress.asrAppendedEnd == 0)
        #expect(ledger.progress.asrConsumedEnd == 0 && ledger.progress.consumedEnd == 0)
        let before = ledger
        #expect(throws: LiveProtocolError.self) { try ledger.recordActualPacketReturn(token) }
        #expect(throws: LiveProtocolError.self) { try ledger.recordASRFlush(scope: f.scope,sampleEnd: 3200) }
        #expect(ledger == before)
    }

    @Test func anOldWindowResultCannotBeReassignedToTheNextOriginalPacket() throws {
        let f = SharedInputFixture(); var ledger = try f.ledger()
        for start in [Int64(0),3200] {
            let token = try f.packet(&ledger,start: start)
            try f.append(&ledger,token,start..<(start+3200),consumed: start+3200)
            try ledger.recordActualPacketReturn(token)
        }
        let current = try f.packet(&ledger,start: 6400), before = ledger
        #expect(throws: LiveProtocolError.self) { try ledger.recordVADProcessed(current,sampleEnd: 4096) }
        #expect(ledger == before)
    }

    @Test func aFullyConsumedAppendStillRequiresItsFirstFinishAndSealedCreditStaysZero() throws {
        let f = SharedInputFixture(); var ledger = try f.ledger()
        let first = try f.packet(&ledger,start: 0)
        try f.append(&ledger,first,0..<3200,consumed: 3200)
        try ledger.recordASRFlush(scope: f.scope,sampleEnd: 3200)
        #expect(ledger.progress.lastASRFinishedEnd == 3200 && ledger.progress.vadProcessedEnd == 0)
        let flushed = ledger
        #expect(throws: LiveProtocolError.self) { try ledger.recordASRFlush(scope: f.scope,sampleEnd: 3200) }
        #expect(ledger == flushed)
        try ledger.recordActualPacketReturn(first)
        let second = try f.packet(&ledger,start: 3200)
        try f.append(&ledger,second,3200..<4096,consumed: 4096)
        try ledger.recordVADProcessed(second,sampleEnd: 4096)
        try f.append(&ledger,second,4096..<6400,consumed: 6400)
        try ledger.seal(scope: f.scope)
        #expect(ledger.progress.creditSamples == 0 && ledger.progress.consumedEnd == 3200)
        try ledger.recordActualPacketReturn(second)
        #expect(ledger.progress.creditSamples == 0 && ledger.progress.consumedEnd == 4096)
        #expect(ledger.progress.pendingSamples == 2304)
    }

    @Test func failedVADActualProofIsScopedProducerBoundAndDoesNotReleaseOriginalWork() async throws {
        let f = SharedInputFixture(), assets = try VADLoadFixture(); defer { assets.cleanup() }
        let runtime = try LiveVADModuleRuntime(input: f.begin(assets.configuration),factory: nil)
        let other = try LiveVADModuleRuntime(input: f.begin(assets.configuration),factory: nil)
        _ = try await runtime.activate(scope: f.scope); _ = try await other.activate(scope: f.scope)
        var ledger = try f.ledger(owner: runtime.ownerID)
        let token = try f.packet(&ledger,start: 0)
        try f.append(&ledger,token,0..<3200,consumed: 3200)
        #expect(ledger.progress.consumedEnd == 0)
        let otherSeal = try await other.retireInput(scope: f.scope)
        let wrongProducer = try await other.settleRetirement(otherSeal.receipt), before = ledger
        #expect(throws: LiveProtocolError.self) { try ledger.recordFailedVADRetirement(wrongProducer) }
        #expect(ledger == before)
        let seal = try await runtime.retireInput(scope: f.scope)
        let proof = try await runtime.settleRetirement(seal.receipt)
        #expect(proof == (try await runtime.settleRetirement(seal.receipt)))
        try ledger.recordFailedVADRetirement(proof)
        #expect(!ledger.progress.vadInputActive && ledger.progress.consumedEnd == 0)
        try ledger.recordActualPacketReturn(token)
        #expect(ledger.progress.consumedEnd == 3200)
        let completed = ledger
        #expect(throws: LiveProtocolError.self) { try ledger.recordFailedVADRetirement(proof) }
        #expect(ledger == completed)
        let fresh = LiveLaneScope(identity: f.scope.identity,source: f.scope.source,epochID: UUID())
        var replacement = try LiveSharedInputLedger(scope: fresh,configuration: f.configuration,vadOwnerID: runtime.ownerID)
        #expect(throws: LiveProtocolError.self) { try replacement.recordFailedVADRetirement(proof) }
        #expect(replacement.progress.vadInputActive)
    }

    @Test func cleanVADRetirementCannotDisableHealthyConsumerOnAnActiveLedger() async throws {
        let f = SharedInputFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let assets = try await a.assets()
        let pool = try await LiveVADModelFactory.load(configuration: a.configuration,sources: [.microphone],assets: assets) { owner,_ in SharedProofHandle(owner) }
        let runtime = try LiveVADModuleRuntime(input: f.begin(a.configuration),factory: pool)
        _ = try await runtime.activate(scope: f.scope)
        var ledger = try f.ledger(owner: runtime.ownerID)
        let token = try f.packet(&ledger,start: 0)
        try f.append(&ledger,token,0..<3200,consumed: 3200); try ledger.recordActualPacketReturn(token)
        let seal = try await runtime.retireInput(scope: f.scope)
        let proof = try await runtime.settleRetirement(seal.receipt), before = ledger
        #expect(!proof.nativeFailureSeen)
        #expect(throws: LiveProtocolError.self) { try ledger.recordFailedVADRetirement(proof) }
        #expect(ledger == before && ledger.progress.consumedEnd == 0)
    }

    @Test func heldFailingNativeWindowProofOmitsOnlyItsInputWhileOriginalPacketStillLives() async throws {
        let f = SharedInputFixture(), a = try VADLoadFixture(); defer { a.cleanup() }
        let nativeRelease = LifetimeSignal(), outerRelease = LifetimeSignal(), nativeAudit = SharedNativeFailureAudit()
        defer { Task { await nativeRelease.signal(); await outerRelease.signal() } }
        let assets = try await a.assets()
        let pool = try await LiveVADModelFactory.load(configuration: a.configuration,sources: [.microphone],assets: assets) { owner,_ in
            SharedFailingHandle(owner,audit: nativeAudit,release: nativeRelease)
        }
        let runtime = try LiveVADModuleRuntime(input: f.begin(a.configuration),factory: pool)
        _ = try await runtime.activate(scope: f.scope)
        var ledger = try f.ledger(owner: runtime.ownerID)
        let first = try f.packet(&ledger,start: 0)
        try f.append(&ledger,first,0..<3200,consumed: 3200)
        _ = try await runtime.admitSlice(scope: f.scope,samples: [Float](repeating: 1,count: 3200),startSample: 0)
        try ledger.recordActualPacketReturn(first)
        let second = try f.packet(&ledger,start: 3200)
        try f.append(&ledger,second,3200..<4096,consumed: 4096)
        guard case .window(let firstWindow) = try await runtime.admitSlice(scope: f.scope,samples: [Float](repeating: 1,count: 896),startSample: 3200) else {
            Issue.record("Missing first actual VAD window"); return
        }
        guard case .processed = try await runtime.complete(firstWindow) else { Issue.record("First window failed"); return }
        try ledger.recordVADProcessed(second,sampleEnd: 4096)
        try f.append(&ledger,second,4096..<6400,consumed: 6400)
        _ = try await runtime.admitSlice(scope: f.scope,samples: [Float](repeating: 1,count: 2304),startSample: 4096)
        try ledger.recordActualPacketReturn(second)
        let third = try f.packet(&ledger,start: 6400), originalAudit = SharedLifetimeAudit()
        var original: SharedOriginalPacket? = .init(); originalAudit.observe(original!)
        let outer = sharedPacketTask(original!,entered: LifetimeSignal(),release: outerRelease); original = nil
        try f.append(&ledger,third,6400..<8192,consumed: 8192)
        guard case .window(let failingWindow) = try await runtime.admitSlice(scope: f.scope,samples: [Float](repeating: 1,count: 1792),startSample: 6400) else {
            Issue.record("Missing held VAD window"); return
        }
        let completion = Task { try await runtime.complete(failingWindow) }
        for _ in 0..<500 { if nativeAudit.isHeld { break }; try? await Task.sleep(for: .milliseconds(2)) }
        try #require(nativeAudit.isHeld)
        #expect(originalAudit.alive && ledger.progress.consumedEnd == 4096)
        #expect(!(try await runtime.progress(scope: f.scope)).inputRetired)
        await nativeRelease.signal()
        guard case .degraded(_,let receipt) = try await completion.value else { Issue.record("Missing failure cleanup"); return }
        let proof = try await runtime.settleRetirement(receipt)
        #expect(proof.nativeFailureSeen && proof.processedEnd == 4096)
        var wrongFrontier = try f.ledger(owner: runtime.ownerID)
        let wrongBefore = wrongFrontier
        #expect(throws: LiveProtocolError.self) { try wrongFrontier.recordFailedVADRetirement(proof) }
        #expect(wrongFrontier == wrongBefore)
        try ledger.recordFailedVADRetirement(proof)
        #expect(originalAudit.alive && ledger.progress.consumedEnd == 6400)
        #expect(ledger.progress.inFlightSamples == 3200 && !ledger.progress.vadInputActive)
        try f.append(&ledger,third,8192..<9600,consumed: 9600)
        #expect(ledger.progress.consumedEnd == 6400)
        await outerRelease.signal(); await outer.value
        #expect(!originalAudit.alive)
        try ledger.recordActualPacketReturn(third)
        #expect(ledger.progress.consumedEnd == 9600 && ledger.progress.pendingSamples == 0)
    }

    @Test func sealedInputNeverGrantsNewConsumerCreditAndStaleTokensCannotTouchFreshLedger() throws {
        let f = SharedInputFixture(); var ledger = try f.ledger()
        let token = try f.packet(&ledger,start: 0)
        try ledger.submitSlice(token,range: 0..<896)
        try ledger.seal(scope: f.scope)
        let sealed = ledger
        #expect(throws: LiveProtocolError.self) { try ledger.recordASRAppend(token,processedEnd: 896,consumedEnd: 896) }
        #expect(throws: LiveProtocolError.self) { try f.admit(&ledger,start: 3200) }
        #expect(throws: LiveProtocolError.self) { try ledger.submitSlice(token,range: 896..<3200) }
        #expect(throws: LiveProtocolError.self) { try ledger.recordASRFlush(scope: f.scope,sampleEnd: 896) }
        #expect(ledger == sealed)
        try ledger.recordActualPacketReturn(token) // Actual return after seal can leave an incomplete slice.
        #expect(ledger.progress.consumedEnd == 0 && ledger.progress.pendingSamples == 3200)
        let fresh = LiveLaneScope(identity: f.scope.identity,source: f.scope.source,epochID: UUID())
        var replacement = try LiveSharedInputLedger(scope: fresh,configuration: f.configuration,vadOwnerID: UUID())
        let before = replacement
        #expect(throws: LiveProtocolError.self) { try replacement.recordActualPacketReturn(token) }
        #expect(replacement == before)
    }

    @Test func actualOuterReturnObserverPreservesOriginalCarrierWhileProcessedPrefixIsHeld() async throws {
        let f = SharedInputFixture(); var ledger = try f.ledger()
        let first = try f.packet(&ledger,start: 0)
        try f.append(&ledger,first,0..<3200,consumed: 3200); try ledger.recordActualPacketReturn(first)
        let second = try f.packet(&ledger,start: 3200)
        let entered = LifetimeSignal(), release = LifetimeSignal(), audit = SharedLifetimeAudit()
        defer { Task { await release.signal() } }
        var original: SharedOriginalPacket? = .init(); audit.observe(original!)
        let task = sharedPacketTask(original!,entered: entered,release: release); original = nil
        for _ in 0..<500 { if audit.alive { break }; try? await Task.sleep(for: .milliseconds(2)) }
        #expect(audit.alive)
        try f.append(&ledger,second,3200..<4096,consumed: 4096)
        try ledger.recordVADProcessed(second,sampleEnd: 4096)
        try f.append(&ledger,second,4096..<6400,consumed: 6400)
        #expect(audit.alive && ledger.progress.consumedEnd == 3200)
        #expect(ledger.progress.inFlightSamples == 3200)
        await release.signal(); await task.value
        #expect(!audit.alive)
        try ledger.recordActualPacketReturn(second)
        #expect(ledger.progress.consumedEnd == 4096 && ledger.progress.pendingSamples == 2304)
    }

    @Test func sameCoordinatesOnDifferentSourcesCannotShareAdmissionsOrCredit() throws {
        let f = SharedInputFixture(); var mic = try f.ledger()
        let systemScope = LiveLaneScope(identity: f.scope.identity,source: .system,epochID: UUID())
        var system = try LiveSharedInputLedger(scope: systemScope,configuration: f.configuration,vadOwnerID: UUID())
        let micReceipt = try f.admit(&mic,start: 0)
        let systemReceipt = try system.admit(scope: systemScope,startSample: 0,sampleCount: 3200)
        let before = system
        #expect(throws: LiveProtocolError.self) { try system.startPacket(micReceipt,startSample: 0,sampleCount: 3200) }
        #expect(system == before)
        let work = try system.startPacket(systemReceipt,startSample: 0,sampleCount: 3200)
        try system.submitSlice(work,range: 0..<3200)
        try system.recordASRAppend(work,processedEnd: 3200,consumedEnd: 3200)
        try system.recordActualPacketReturn(work)
        #expect(mic.progress.queuedSamples == 3200 && system.progress.heldSamples == 3200)
    }
}
