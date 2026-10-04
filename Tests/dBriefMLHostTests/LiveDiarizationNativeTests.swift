import CoreML
import FluidAudio
import Foundation
import Testing
@testable import dBriefWire
@testable import dBriefMLHost

enum DiarizationContractFixture {
    static func metadata(_ p: LiveDiarizationPreset = .low) -> [String:Any] {
        func features(_ shapes: [String:[Int]],input: Bool) -> [[String:Any]] {
            shapes.keys.sorted().map { name in
                ["name":name,"type":"MultiArray","dataType":input && name.hasSuffix("_lengths") ? "Int32" : "Float32",
                 "isOptional":"0","hasShapeFlexibility":"0","shape":String(data: try! JSONEncoder().encode(shapes[name]!),encoding: .utf8)!]
            }
        }
        return ["metadataOutputVersion":"3.0","version":"fixture","modelType":["name":"MLModelType_mlProgram"],
                "isUpdatable":"0","stateSchema":[],"method":"predict",
                "inputSchema":features(LiveDiarizationModelContract.inputShapes(p),input: true),
                "outputSchema":features(LiveDiarizationModelContract.outputShapes(p),input: false)]
    }
    static func data(_ p: LiveDiarizationPreset = .low) throws -> Data { try data(metadata(p)) }
    static func data(_ value: [String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject: [value],options: [.sortedKeys]) }
    static func description(_ p: LiveDiarizationPreset = .low) -> LiveDiarizationModelContract.Description {
        .init(inputs: LiveDiarizationModelContract.inputShapes(p).map { .init(name: $0.key,shape: $0.value,element: $0.key.hasSuffix("_lengths") ? .int32 : .float32) },
              outputs: LiveDiarizationModelContract.outputShapes(p).map { .init(name: $0.key,shape: $0.value) })
    }
}
private final class DiarizationNativeAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private weak var snapshot: LiveDiarizationReadOnlySnapshot?
    private var nativeGone = false, ordered = false, done = false
    func observe(_ value: LiveDiarizationReadOnlySnapshot) { lock.withLock { snapshot = value } }
    func hit(_ name: String) { lock.withLock { calls.append(name) } }
    func release() { lock.withLock { nativeGone = true; ordered = snapshot != nil } }
    func complete() { lock.withLock { done = true } }
    var events: [String] { lock.withLock { calls } }
    var alive: Bool { lock.withLock { snapshot != nil } }
    var released: Bool { lock.withLock { nativeGone } }
    var orderedRelease: Bool { lock.withLock { ordered } }
    var completed: Bool { lock.withLock { done } }
}
private final class DiarizationBlockingNativeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false, released = false
    var isEntered: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func hold() throws {
        condition.lock(); defer { condition.unlock() }; entered = true
        let deadline = Date().addingTimeInterval(60)
        while !released { guard condition.wait(until: deadline) else { throw LiveDiarizationNativeError.failed } }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
private final class DiarizationTestNativeObject: LiveDiarizationModelObject, Sendable {
    let snapshot: LiveDiarizationReadOnlySnapshot
    let audit: DiarizationNativeAudit
    let chunks: [LiveDiarizationChunk]
    let gate: DiarizationBlockingNativeGate?
    init(_ snapshot: LiveDiarizationReadOnlySnapshot,_ audit: DiarizationNativeAudit,chunks: [LiveDiarizationChunk],gate: DiarizationBlockingNativeGate? = nil) {
        self.snapshot = snapshot; self.audit = audit; self.chunks = chunks; self.gate = gate; audit.observe(snapshot)
    }
    func append(_ samples: [Float]) throws -> [LiveDiarizationChunk] { audit.hit("append"); try gate?.hold(); return chunks }
    func finish() throws -> [LiveDiarizationChunk] { audit.hit("finish"); return [.init(frameCount: 0,probabilities: [])] }
    deinit { audit.release(); withExtendedLifetime(snapshot) {} }
}
private actor DiarizationLoaderTestDriver: LiveDiarizationDriving {
    private var snapshot: LiveDiarizationReadOnlySnapshot?
    private let shutdownGate: DiarizationAssetGate?
    init(_ snapshot: LiveDiarizationReadOnlySnapshot,shutdown: DiarizationAssetGate? = nil) { self.snapshot = snapshot; shutdownGate = shutdown }
    func append(_ samples: [Float]) -> [LiveDiarizationChunk] { [] }
    func finish() -> [LiveDiarizationChunk] { [] }
    func shutdown() async { await shutdownGate?.hold(); snapshot = nil }
}
private struct DiarizationLoaderPayloadError: Error { let snapshot: LiveDiarizationReadOnlySnapshot }

@Suite struct LiveDiarizationNativeTests {
    @Test(arguments: LiveDiarizationPreset.allCases)
    func frozenSdkPresetAndComputeUseExactWireShapes(preset: LiveDiarizationPreset) throws {
        let c = LiveDiarizationConfiguration(identity: .init(modelFingerprint: String(repeating: "a",count: 64),preset: preset,computeUnits: .cpuOnly),modelDirectory: "/private/tmp/unused")
        let native = try LiveDiarizationNativeConfiguration(c), sdk = native.sdk
        #expect(sdk.chunkLen == preset.core && sdk.chunkRightContext == preset.right && sdk.chunkLeftContext == 0)
        #expect(sdk.spkcacheLen == 264 && sdk.fifoLen == preset.fifo && !sdk.splitGraph && sdk.modelFileName == preset.modelFileName)
        #expect(native.modelConfiguration().computeUnits == .cpuOnly && !native.modelConfiguration().allowLowPrecisionAccumulationOnGPU)
        // Independent SDK oracle: fixture metadata must not validate a shared wrong formula.
        #expect(LiveDiarizationModelContract.inputShapes(preset) == [
            "chunk":[1,sdk.chunkMelFrames,sdk.melFeatures],"chunk_lengths":[1],
            "spkcache":[1,sdk.spkcacheLen,sdk.preEncoderDims],"spkcache_lengths":[1],
            "fifo":[1,sdk.fifoLen,sdk.preEncoderDims],"fifo_lengths":[1]])
        #expect(LiveDiarizationModelContract.outputShapes(preset) == [
            "speaker_preds":[1,sdk.packedFrames,sdk.numSpeakers],
            "speaker_preds_10ms":[1,sdk.packedFrames*sdk.upsampleFactor,sdk.numSpeakers],
            "chunk_pre_encode_embs":[1,sdk.chunkEncFrames,sdk.preEncoderDims]])
        let contract = try LiveDiarizationModelContract(metadata: DiarizationContractFixture.data(preset),preset: preset)
        var description = DiarizationContractFixture.description(preset)
        try contract.validate(description)
        for i in description.outputs.indices { description.outputs[i].flexibility = .range(description.outputs[i].shape.map { .init(location: $0,length: 1) }) }
        try contract.validate(description)
    }

    @Test(arguments: ["missing","extra","duplicate","optional","float-length","double","flex","shape","integer-alias","state","update","format","method"])
    func metadataCannotAuthorizeUnboundedOrDifferentNativeShapes(mode: String) throws {
        var json = DiarizationContractFixture.metadata(), inputs = try #require(json["inputSchema"] as? [[String:Any]])
        switch mode {
        case "missing": inputs.removeLast()
        case "extra": inputs.append(["name":"unknown"])
        case "duplicate": inputs[1] = inputs[0]
        case "optional": inputs[0]["isOptional"] = "1"
        case "float-length": inputs[1]["dataType"] = "Float32"
        case "double": inputs[0]["dataType"] = "Double"
        case "flex": inputs[0]["hasShapeFlexibility"] = "1"
        case "shape": inputs[0]["shape"] = "[1, 999999999, 128]"
        case "integer-alias": inputs[0]["shape"] = "[1.0,104,128]"
        case "state": json["stateSchema"] = [["name":"state"]]
        case "update": json["isUpdatable"] = "1"
        case "format": json["metadataOutputVersion"] = "4.0"
        default: json["method"] = "other"
        }
        json["inputSchema"] = inputs
        #expect(throws: LiveDiarizationNativeError.invalidModel) { _ = try LiveDiarizationModelContract(metadata: DiarizationContractFixture.data(json),preset: .low) }
    }

    @Test(arguments: ["extra","duplicate","optional","dtype","shape","enumerated","range","state","update"])
    func nativeDescriptionMustMatchVerifiedFixedMetadata(mode: String) throws {
        let contract = try LiveDiarizationModelContract(metadata: DiarizationContractFixture.data(),preset: .low)
        var d = DiarizationContractFixture.description()
        switch mode {
        case "extra": d.outputs.append(.init(name: "advisory",shape: [1]))
        case "duplicate": d.outputs[1] = d.outputs[0]
        case "optional": d.outputs[0].isOptional = true
        case "dtype": d.outputs[0].element = .float16
        case "shape": d.outputs[0].shape = [1,1,8]
        case "enumerated": d.outputs[0].flexibility = .enumerated([d.outputs[0].shape,[1]])
        case "range": d.outputs[0].flexibility = .range(d.outputs[0].shape.map { .init(location: $0,length: 2) })
        case "state": d.stateCount = 1
        default: d.isUpdatable = true
        }
        #expect(throws: LiveDiarizationNativeError.invalidModel) { try contract.validate(d) }
    }

    @Test func float16MetadataStillRequiresTheExactNativeDescriptionAndBoundedBytes() throws {
        var json = DiarizationContractFixture.metadata()
        for key in ["inputSchema","outputSchema"] {
            var features = try #require(json[key] as? [[String:Any]])
            for i in features.indices where features[i]["dataType"] as? String == "Float32" { features[i]["dataType"] = "Float16" }
            json[key] = features
        }
        let metadata = try DiarizationContractFixture.data(json), contract = try LiveDiarizationModelContract(metadata: metadata,preset: .low)
        var description = DiarizationContractFixture.description()
        for i in description.inputs.indices where description.inputs[i].element == .float32 { description.inputs[i].element = .float16 }
        for i in description.outputs.indices { description.outputs[i].element = .float16 }
        try contract.validate(description)
        #expect(throws: LiveDiarizationNativeError.invalidModel) { try contract.validate(DiarizationContractFixture.description()) }
        for bytes in [Data(),Data(repeating: 32,count: 65_537)] {
            #expect(throws: LiveDiarizationNativeError.invalidModel) { _ = try LiveDiarizationModelContract(metadata: bytes,preset: .low) }
        }
    }

    @Test func foreignSnapshotAndMetadataWitnessCannotEnterSealedConstruction() async throws {
        let f = try DiarizationAssetsFixture(metadata: DiarizationContractFixture.data()); defer { f.remove() }
        let a = try f.assets(), owner = UUID(), audit = DiarizationNativeAudit()
        try #require(a.bind(to: owner)); try await a.prepare(owner: owner)
        let s = try a.snapshot(owner: owner), other = try a.snapshot(owner: owner)
        #expect(throws: LiveDiarizationNativeError.invalidModel) {
            _ = try LiveDiarizationOwnedDriver(snapshot: s,object: DiarizationTestNativeObject(other,audit,chunks: []))
        }
        var foreign = DiarizationContractFixture.metadata(); foreign["version"] = "different bytes"
        let request = LiveDiarizationNativeLoadRequest(snapshot: s,policy: try .init(a.configuration),
            contract: try .init(metadata: DiarizationContractFixture.data(foreign),preset: .low))
        // Digest rejection occurs before any real CoreML model constructor.
        #expect(throws: LiveDiarizationNativeError.invalidConfiguration) { _ = try LiveDiarizationOwnedDriver.load(request) }
        await a.retire(owner: owner)?.value
    }

    @Test(arguments: ["family","revision","runtime","implementation","fingerprint","precision","path"])
    func unsupportedIdentityCannotReachNativeConstructor(mode: String) async throws {
        let audit = DiarizationNativeAudit()
        let identity = LiveDiarizationIdentity(family: mode == "family" ? "foreign" : LiveDiarizationIdentity.modelFamily,
            modelRevision: mode == "revision" ? "foreign" : LiveDiarizationIdentity.currentModelRevision,
            modelFingerprint: String(repeating: "a",count: mode == "fingerprint" ? 65 : 64),
            runtimeRevision: mode == "runtime" ? "foreign" : LiveASRIdentity.currentRuntimeRevision,
            implementationRevision: mode == "implementation" ? "foreign" : LiveDiarizationIdentity.currentImplementationRevision,
            preset: .low,allowLowPrecisionGPUAccumulation: mode == "precision")
        let c = LiveDiarizationConfiguration(identity: identity,modelDirectory: mode == "path" ? "/private/tmp/../foreign" : "/private/tmp/unused")
        await #expect(throws: LiveDiarizationNativeError.invalidConfiguration) {
            _ = try await LiveDiarizationNativeLoader.load(c,environment: [:],constructor: { _ in audit.hit("constructor"); throw LiveDiarizationNativeError.failed })
        }
        #expect(audit.events.isEmpty)
    }

    @Test func successfulLoadsHaveIndependentSnapshotOwnersAndShutdown() async throws {
        let f = try DiarizationAssetsFixture(metadata: DiarizationContractFixture.data()); defer { f.remove() }
        let a = try f.assets(), owner = UUID(), first = DiarizationNativeAudit(), second = DiarizationNativeAudit()
        try #require(a.bind(to: owner)); try await a.prepare(owner: owner)
        let d1 = try await LiveDiarizationNativeLoader.load(a.configuration,testingStagingDirectory: f.staging,environment: [:],constructor: {
            try LiveDiarizationOwnedDriver(snapshot: $0.snapshot,object: DiarizationTestNativeObject($0.snapshot,first,chunks: []))
        })
        let d2 = try await LiveDiarizationNativeLoader.load(a.configuration,testingStagingDirectory: f.staging,environment: [:],constructor: {
            try LiveDiarizationOwnedDriver(snapshot: $0.snapshot,object: DiarizationTestNativeObject($0.snapshot,second,chunks: []))
        })
        #expect(ObjectIdentifier(d1) != ObjectIdentifier(d2) && first.alive && second.alive)
        await d1.shutdown(); #expect(!first.alive && first.orderedRelease && second.alive && !second.released)
        #expect(try await d2.append([0]).isEmpty)
        await d2.shutdown(); #expect(!second.alive && second.orderedRelease)
        await a.retire(owner: owner)?.value
    }

    @Test func actualOwnedDriverGuardsTerminalCallsAndReleasesNativeBeforeSnapshot() async throws {
        let f = try DiarizationAssetsFixture(); defer { f.remove() }
        let a = try f.assets(), owner = UUID(), audit = DiarizationNativeAudit()
        try #require(a.bind(to: owner)); try await a.prepare(owner: owner)
        func driver() throws -> LiveDiarizationOwnedDriver {
            let s = try a.snapshot(owner: owner)
            return try .init(snapshot: s,object: DiarizationTestNativeObject(s,audit,chunks: [.init(frameCount: 1,probabilities: Array(repeating: 0.25,count: 8))]))
        }
        let d = try driver()
        #expect(try await d.append(Array(repeating: 0,count: 160)).count == 1)
        let first = try await d.finish(), replay = try await d.finish()
        #expect(first.isEmpty && replay.isEmpty)
        await #expect(throws: LiveDiarizationNativeError.inactive) { try await d.append([0]) }
        #expect(audit.events == ["append","finish"] && audit.alive && !audit.released)
        await d.shutdown()
        #expect(audit.released && audit.orderedRelease && !audit.alive)
        await #expect(throws: LiveDiarizationNativeError.inactive) { try await d.finish() }
        await a.retire(owner: owner)?.value
    }

    @Test func malformedWholeBatchRetiresDriverWithoutDroppingNativeEarly() async throws {
        let f = try DiarizationAssetsFixture(); defer { f.remove() }
        let a = try f.assets(), owner = UUID(), audit = DiarizationNativeAudit()
        try #require(a.bind(to: owner)); try await a.prepare(owner: owner)
        func driver() throws -> LiveDiarizationOwnedDriver {
            let s = try a.snapshot(owner: owner)
            return try .init(snapshot: s,object: DiarizationTestNativeObject(s,audit,chunks: [
                .init(frameCount: 1,probabilities: Array(repeating: 0.25,count: 8)),.init(frameCount: 1,probabilities: Array(repeating: .nan,count: 8))]))
        }
        let d = try driver()
        await #expect(throws: LiveDiarizationNativeError.failed) { try await d.append(Array(repeating: 0,count: 320)) }
        await #expect(throws: LiveDiarizationNativeError.inactive) { try await d.append([0]) }
        #expect(audit.events == ["append"] && audit.alive && !audit.released)
        await d.shutdown(); #expect(audit.orderedRelease && !audit.alive)
        await a.retire(owner: owner)?.value
    }

    @Test func cancellationAndQueuedShutdownWaitForActualSynchronousNativeReturn() async throws {
        let f = try DiarizationAssetsFixture(); defer { f.remove() }
        let a = try f.assets(), owner = UUID(), audit = DiarizationNativeAudit(), gate = DiarizationBlockingNativeGate()
        defer { gate.release() }
        try #require(a.bind(to: owner)); try await a.prepare(owner: owner)
        func driver() throws -> LiveDiarizationOwnedDriver {
            let s = try a.snapshot(owner: owner)
            return try .init(snapshot: s,object: DiarizationTestNativeObject(s,audit,chunks: [.init(frameCount: 1,probabilities: Array(repeating: 0.25,count: 8))],gate: gate))
        }
        let d = try driver(), append = Task { try await d.append(Array(repeating: 0,count: 160)) }
        guard await diarAssetEventually({ gate.isEntered }) else { gate.release(); _ = await append.result; await d.shutdown(); await a.retire(owner: owner)?.value; Issue.record("native call never entered"); return }
        append.cancel()
        let close = Task { await d.shutdown(); audit.complete() }; close.cancel()
        #expect(audit.alive && !audit.released && !audit.completed && audit.events == ["append"])
        gate.release(); if case .success = await append.result { Issue.record("canceled native operation published") }; await close.value
        #expect(audit.completed && audit.orderedRelease && !audit.alive)
        await a.retire(owner: owner)?.value
    }

    @Test func canceledPreconstructionNeverEntersConstructor() async throws {
        let f = try DiarizationAssetsFixture(metadata: DiarizationContractFixture.data()); defer { f.remove() }
        let a = try f.assets(), owner = UUID(), audit = DiarizationNativeAudit(), gate = DiarizationAssetGate()
        try #require(a.bind(to: owner)); try await a.prepare(owner: owner)
        let load = Task { defer { audit.complete() }; return try await LiveDiarizationNativeLoader.load(a.configuration,testingStagingDirectory: f.staging,environment: [:],beforeConstruction: { await gate.hold() },constructor: {
            audit.hit("constructor"); return DiarizationLoaderTestDriver($0.snapshot)
        }) }
        guard await diarAssetEventually({ await gate.entered }) else { load.cancel(); await gate.release(); _ = await load.result; await a.retire(owner: owner)?.value; Issue.record("preconstruction never entered"); return }
        load.cancel(); #expect(!audit.completed && audit.events.isEmpty)
        await gate.release(); if case .success = await load.result { Issue.record("canceled loader returned driver") }
        #expect(audit.completed && audit.events.isEmpty)
        await a.retire(owner: owner)?.value
    }

    @Test func canceledConstructorAndShutdownRetainSnapshotUntilActualReturns() async throws {
        let f = try DiarizationAssetsFixture(metadata: DiarizationContractFixture.data()); defer { f.remove() }
        let a = try f.assets(), owner = UUID(), audit = DiarizationNativeAudit(), construct = DiarizationAssetGate(), shutdown = DiarizationAssetGate()
        try #require(a.bind(to: owner)); try await a.prepare(owner: owner)
        let load = Task { defer { audit.complete() }; return try await LiveDiarizationNativeLoader.load(a.configuration,testingStagingDirectory: f.staging,environment: [:],constructor: {
            audit.observe($0.snapshot); audit.hit("constructor"); await construct.hold()
            return DiarizationLoaderTestDriver($0.snapshot,shutdown: shutdown)
        }) }
        guard await diarAssetEventually({ await construct.entered }) else { load.cancel(); await construct.release(); await shutdown.release(); _ = await load.result; await a.retire(owner: owner)?.value; Issue.record("constructor never entered"); return }
        load.cancel(); #expect(audit.alive && !audit.completed)
        await construct.release()
        guard await diarAssetEventually({ await shutdown.entered }) else { await shutdown.release(); _ = await load.result; await a.retire(owner: owner)?.value; Issue.record("shutdown never entered"); return }
        #expect(audit.alive && !audit.completed && FileManager.default.fileExists(atPath: a.configuration.modelDirectory))
        await shutdown.release(); if case .success = await load.result { Issue.record("canceled loader returned driver") }
        #expect(!audit.alive && audit.completed)
        await a.retire(owner: owner)?.value
    }

    @Test func cachedLoaderFailureContainsNoArbitrarySnapshotPayload() async throws {
        let f = try DiarizationAssetsFixture(metadata: DiarizationContractFixture.data()); defer { f.remove() }
        let a = try f.assets(), owner = UUID(), audit = DiarizationNativeAudit()
        try #require(a.bind(to: owner)); try await a.prepare(owner: owner)
        let load = Task { try await LiveDiarizationNativeLoader.load(a.configuration,testingStagingDirectory: f.staging,environment: [:],constructor: {
            audit.observe($0.snapshot); throw DiarizationLoaderPayloadError(snapshot: $0.snapshot)
        }) }
        let result = await load.result
        if case .failure(let error) = result { #expect(error as? LiveDiarizationNativeError == .failed) }
        else { Issue.record("error returned driver") }
        #expect(!audit.alive)
        withExtendedLifetime(result) {}; withExtendedLifetime(load) {}
        await #expect(throws: LiveDiarizationNativeError.invalidConfiguration) { _ = try await LiveDiarizationNativeLoader.load(a.configuration,environment: ["FLUIDAUDIO_OVERRIDE":"1"]) }
        await a.retire(owner: owner)?.value
    }
}
