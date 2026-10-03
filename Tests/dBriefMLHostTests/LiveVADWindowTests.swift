import Foundation
import Testing
import dBriefWire
@testable import dBriefMLHost

private actor WindowPredictor: LiveVADPredicting {
    private(set) var inputs: [LiveVADNativeInput] = []
    let entered: LifetimeSignal?
    let release: LifetimeSignal?
    let invalidFirst: Bool
    init(entered: LifetimeSignal? = nil, release: LifetimeSignal? = nil, invalidFirst: Bool = false) {
        self.entered = entered; self.release = release; self.invalidFirst = invalidFirst
    }
    func predict(_ input: LiveVADNativeInput) async throws -> LiveVADNativeOutput {
        inputs.append(input)
        await entered?.signal(); await release?.wait()
        return try .init(probability: invalidFirst && inputs.count == 1 ? .nan : 0.25,
            hiddenState: [Float](repeating: Float(inputs.count),count: 128),cellState: [Float](repeating: -Float(inputs.count),count: 128))
    }
}
private final class WindowNativeAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0, ended = false, invalid = false
    private weak var asset: LiveVADModelAssets?
    func call() { lock.withLock { stored += 1 } }
    var calls: Int { lock.withLock { stored } }
    func finish() { lock.withLock { ended = true } }
    var finished: Bool { lock.withLock { ended } }
    func invalidate() { lock.withLock { invalid = true } }
    var invalidDescription: Bool { lock.withLock { invalid } }
    func observe(_ assets: LiveVADModelAssets) { lock.withLock { asset = assets } }
    var assetAlive: Bool { lock.withLock { asset != nil } }
}
private final class WindowNativeModel: LiveVADModelObject, Sendable {
    let assets: LiveVADModelAssets
    let audit: WindowNativeAudit
    let entered: DispatchSemaphore?
    let release: DispatchSemaphore?
    init(assets: LiveVADModelAssets, audit: WindowNativeAudit, entered: DispatchSemaphore? = nil, release: DispatchSemaphore? = nil) {
        self.assets = assets; self.audit = audit; self.entered = entered; self.release = release
    }
    func validate(_ contract: LiveVADModelContract) throws {
        var description = VADLoadFixture.description
        if audit.invalidDescription { description.outputs.removeLast() }
        try contract.validate(description)
    }
    func predict(_ input: LiveVADNativeInput) throws -> LiveVADNativeOutput {
        audit.call(); entered?.signal(); release?.wait()
        #expect(input.audio.count == 4160 && input.hiddenState.count == 128 && input.cellState.count == 128)
        return try .init(probability: 0.25,hiddenState: [Float](repeating: 1,count: 128),cellState: [Float](repeating: -1,count: 128))
    }
}

@Suite struct LiveVADWindowTests {
    private func input() throws -> LiveVADNativeInput {
        try .init(audio: [Float](repeating: 0,count: 4160),hiddenState: [Float](repeating: 0,count: 128),cellState: [Float](repeating: 0,count: 128))
    }
    @Test(arguments: ["short-audio","long-audio","short-hidden","long-cell","audio-nan","hidden-infinity","cell-nan"])
    func malformedNativeInputCannotBecomeAValidTypedValue(mode: String) throws {
        var audio = [Float](repeating: 0,count: 4160), hidden = [Float](repeating: 0,count: 128), cell = hidden
        switch mode {
        case "short-audio": audio.removeLast()
        case "long-audio": audio.append(0)
        case "short-hidden": hidden.removeLast()
        case "long-cell": cell.append(0)
        case "audio-nan": audio[4159] = .nan
        case "hidden-infinity": hidden[127] = .infinity
        default: cell[127] = .nan
        }
        #expect(throws: LiveVADModelError.invalidInput) { _ = try LiveVADNativeInput(audio: audio,hiddenState: hidden,cellState: cell) }
    }

    @Test(arguments: ["short-hidden","long-cell","nan","infinity","negative","above-one","hidden-nan","cell-infinity"])
    func malformedNativeOutputCannotBecomeAValidTypedValue(mode: String) throws {
        var probability: Float = 0.25, hidden = [Float](repeating: 1,count: 128), cell = [Float](repeating: -1000,count: 128)
        switch mode {
        case "short-hidden": hidden.removeLast()
        case "long-cell": cell.append(0)
        case "nan": probability = .nan
        case "infinity": probability = .infinity
        case "negative": probability = -0.01
        case "above-one": probability = 1.01
        case "hidden-nan": hidden[127] = .nan
        default: cell[127] = .infinity
        }
        #expect(throws: LiveVADModelError.invalidOutput) { _ = try LiveVADNativeOutput(probability: probability,hiddenState: hidden,cellState: cell) }
    }

    @Test func consecutiveWindowsCarryExactlyLastContextAndWholeReturnedState() async throws {
        let predictor = WindowPredictor(), session = try LiveVADWindowSession(source: .microphone,predictor: predictor)
        let first = (0..<4096).map(Float.init), second = [Float](repeating: -2,count: 4096)
        let a = try await session.process(samples: first,startSample: 0), b = try await session.process(samples: second,startSample: 4096)
        #expect(a.sampleStart == 0 && a.sampleEnd == 4096 && b.sampleEnd == 8192 && b.probability == 0.25)
        let inputs = await predictor.inputs
        #expect(inputs.count == 2 && inputs[0].audio == [Float](repeating: 0,count: 64)+first)
        #expect(inputs[0].hiddenState == [Float](repeating: 0,count: 128) && inputs[0].cellState == inputs[0].hiddenState)
        #expect(inputs[1].audio == Array(first.suffix(64))+second)
        #expect(inputs[1].hiddenState == [Float](repeating: 1,count: 128) && inputs[1].cellState == [Float](repeating: -1,count: 128))
        #expect(await session.progress().processedEnd == 8192)
    }

    @Test(arguments: ["short","long","nan","infinity","past","future","overflow"])
    func invalidWindowNeverCallsPredictionOrChangesEndpoint(mode: String) async throws {
        let predictor = WindowPredictor(), origin: Int64 = mode == "overflow" ? .max-2048 : 0
        let session = try LiveVADWindowSession(source: .system,predictor: predictor,sampleStart: origin)
        var samples = [Float](repeating: 1,count: 4096), start = origin
        switch mode {
        case "short": samples.removeLast()
        case "long": samples.append(1)
        case "nan": samples[4095] = .nan
        case "infinity": samples[0] = .infinity
        case "past": start = -1
        case "future": start = 4096
        default: break
        }
        await #expect(throws: LiveVADWindowError.invalidWindow) { _ = try await session.process(samples: samples,startSample: start) }
        let inputs = await predictor.inputs, progress = await session.progress()
        #expect(inputs.isEmpty && progress.processedEnd == origin)
    }

    @Test func failedOutputPreservesStateAndExactRetryFrontier() async throws {
        let predictor = WindowPredictor(invalidFirst: true), session = try LiveVADWindowSession(source: .microphone,predictor: predictor)
        let samples = [Float](repeating: 3,count: 4096)
        await #expect(throws: LiveVADModelError.invalidOutput) { _ = try await session.process(samples: samples,startSample: 0) }
        #expect(await session.progress().processedEnd == 0)
        _ = try await session.process(samples: samples,startSample: 0)
        let inputs = await predictor.inputs
        #expect(inputs.count == 2 && inputs[1] == inputs[0])
        #expect(await session.progress().processedEnd == 4096)
    }

    @Test func canceledBeforeWindowInvokesNothing() async throws {
        let predictor = WindowPredictor(), session = try LiveVADWindowSession(source: .microphone,predictor: predictor), start = LifetimeSignal()
        let task = Task {
            await start.wait()
            return try await session.process(samples: [Float](repeating: 1,count: 4096),startSample: 0)
        }
        task.cancel(); await start.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let inputs = await predictor.inputs, progress = await session.progress()
        #expect(inputs.isEmpty && progress.processedEnd == 0)
    }

    @Test func canceledIgnoringPredictionRemainsInFlightAndCannotCommit() async throws {
        let entered = LifetimeSignal(), release = LifetimeSignal(), audit = WindowNativeAudit()
        let predictor = WindowPredictor(entered: entered,release: release), session = try LiveVADWindowSession(source: .microphone,predictor: predictor)
        let task = Task {
            defer { audit.finish() }
            return try await session.process(samples: [Float](repeating: 7,count: 4096),startSample: 0)
        }
        await entered.wait(); task.cancel()
        let held = await session.progress()
        #expect(held.hasInFlight && held.processedEnd == 0 && !audit.finished)
        await release.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let done = await session.progress()
        #expect(!done.hasInFlight && done.processedEnd == 0)
        _ = try await session.process(samples: [Float](repeating: 7,count: 4096),startSample: 0)
        let inputs = await predictor.inputs
        #expect(inputs.count == 2 && inputs[1] == inputs[0])
    }

    @Test func overlappingWindowRefusesAndRetirementWaitsForActualOldResult() async throws {
        let entered = LifetimeSignal(), release = LifetimeSignal(), audit = WindowNativeAudit()
        let predictor = WindowPredictor(entered: entered,release: release), session = try LiveVADWindowSession(source: .system,predictor: predictor)
        let samples = [Float](repeating: 1,count: 4096)
        let task = Task { defer { audit.finish() }; return try await session.process(samples: samples,startSample: 0) }
        await entered.wait()
        await #expect(throws: LiveVADWindowError.overlap) { _ = try await session.process(samples: samples,startSample: 0) }
        await session.retire()
        let held = await session.progress()
        #expect(!held.isActive && held.hasInFlight && held.processedEnd == 0 && !audit.finished)
        await #expect(throws: LiveVADWindowError.inactive) { _ = try await session.process(samples: samples,startSample: 0) }
        await release.signal()
        await #expect(throws: LiveVADWindowError.inactive) { _ = try await task.value }
        let inputs = await predictor.inputs, progress = await session.progress()
        #expect(inputs.count == 1 && !progress.hasInFlight)
    }

    @Test func sourcesAndFreshContinuityDoNotShareRecurrentState() async throws {
        let micPredictor = WindowPredictor(), systemPredictor = WindowPredictor()
        let mic = try LiveVADWindowSession(source: .microphone,predictor: micPredictor), system = try LiveVADWindowSession(source: .system,predictor: systemPredictor)
        _ = try await mic.process(samples: [Float](repeating: 1,count: 4096),startSample: 0)
        _ = try await mic.process(samples: [Float](repeating: 2,count: 4096),startSample: 4096)
        _ = try await system.process(samples: [Float](repeating: 3,count: 4096),startSample: 0)
        let systemInput = try #require(await systemPredictor.inputs.first)
        #expect(systemInput.hiddenState == [Float](repeating: 0,count: 128) && systemInput.audio.prefix(64).allSatisfy { $0 == 0 })
        await mic.retire()
        let fresh = try LiveVADWindowSession(source: .microphone,predictor: micPredictor)
        _ = try await fresh.process(samples: [Float](repeating: 4,count: 4096),startSample: 0)
        let freshInput = try #require(await micPredictor.inputs.last)
        #expect(freshInput.hiddenState == [Float](repeating: 0,count: 128) && freshInput.cellState == freshInput.hiddenState)
        #expect(freshInput.audio.prefix(64).allSatisfy { $0 == 0 })
    }

    @Test func unvalidatedOrFailedRevalidatedHandleNeverInvokesNativePrediction() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let assets = try await f.assets(), audit = WindowNativeAudit(), input = try input()
        let handle = LiveVADOwnedModelHandle(assets: assets,model: WindowNativeModel(assets: assets,audit: audit))
        await #expect(throws: LiveVADModelError.invalidModel) { _ = try await handle.predict(input) }
        #expect(audit.calls == 0)
        let contract = try LiveVADModelContract(cachedMetadata: assets.readMetadata())
        try await handle.validate(contract); _ = try await handle.predict(input)
        #expect(audit.calls == 1)
        audit.invalidate()
        await #expect(throws: LiveVADModelError.invalidModel) { try await handle.validate(contract) }
        await #expect(throws: LiveVADModelError.invalidModel) { _ = try await handle.predict(input) }
        #expect(audit.calls == 1)
    }

    @Test func ownedHandleWaitsForSynchronousUnwindAndSkipsCanceledQueuedPrediction() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let assets = try await f.assets(), audit = WindowNativeAudit(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let handle = LiveVADOwnedModelHandle(assets: assets,model: WindowNativeModel(assets: assets,audit: audit,entered: entered,release: release))
        try await handle.validate(LiveVADModelContract(cachedMetadata: assets.readMetadata()))
        let input = try input(), queued = LifetimeSignal()
        let first = Task { try await handle.predict(input) }
        defer { release.signal() }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now()+5) == .success) }
        }
        if !started { first.cancel(); release.signal(); _ = try? await first.value }
        try #require(started)
        let second = Task { await queued.signal(); return try await handle.predict(input) }
        await queued.wait(); second.cancel(); first.cancel()
        #expect(audit.calls == 1)
        release.signal()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        await #expect(throws: CancellationError.self) { _ = try await second.value }
        #expect(audit.calls == 1)
    }

    @Test func canceledRevalidationCannotLeaveAnEarlierSchemaGateOpen() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let assets = try await f.assets(), audit = WindowNativeAudit(), start = LifetimeSignal(), input = try input()
        let handle = LiveVADOwnedModelHandle(assets: assets,model: WindowNativeModel(assets: assets,audit: audit))
        let contract = try LiveVADModelContract(cachedMetadata: assets.readMetadata())
        try await handle.validate(contract)
        let task = Task { await start.wait(); try await handle.validate(contract) }
        task.cancel(); await start.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: LiveVADModelError.invalidModel) { _ = try await handle.predict(input) }
        #expect(audit.calls == 0)
    }

    @Test func canceledHeldPredictionOwnsSnapshotAfterExternalReferencesDisappear() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let audit = WindowNativeAudit(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var assets: LiveVADModelAssets? = try await f.assets()
        audit.observe(try #require(assets)); let path = try #require(try assets?.modelDirectory)
        var handle: LiveVADOwnedModelHandle? = LiveVADOwnedModelHandle(assets: try #require(assets),
            model: WindowNativeModel(assets: try #require(assets),audit: audit,entered: entered,release: release))
        try await handle?.validate(LiveVADModelContract(cachedMetadata: try #require(assets).readMetadata()))
        let input = try input()
        let task = Task { [owner = try #require(handle)] in try await owner.predict(input) }
        assets = nil; handle = nil
        defer { release.signal() }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now()+5) == .success) }
        }
        if !started { task.cancel(); release.signal(); _ = try? await task.value }
        try #require(started)
        task.cancel()
        #expect(audit.calls == 1 && audit.assetAlive && FileManager.default.fileExists(atPath: path.path))
        release.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!audit.assetAlive && !FileManager.default.fileExists(atPath: path.path) && f.staged.isEmpty)
    }
}
