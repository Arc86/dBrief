import Foundation
import Testing
@testable import dBriefWire
@testable import dBriefMLHost

private struct NativeASRFixture {
    static let fingerprint = "5b62fde7e92de6139cb9992d20b48f492c3704d48c2bbc79d51b6b200e369542"
    static var configuration: LiveASRConfiguration {
        .init(language: .auto,chunkMs: 1120,modelDirectory: "/private/tmp/frozen-native-assets",
            identity: .init(modelRevision: "fixture-asr",modelFingerprint: fingerprint,runtimeRevision: LiveASRIdentity.currentRuntimeRevision))
    }
    static func metadata() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["sample_rate":16000,"mel_features":128,"chunk_mel_frames":112,"chunk_ms":1120,
            "pre_encode_cache":9,"total_mel_frames":121,"vocab_size":13087,"blank_idx":13087,"encoder_dim":1024,"decoder_hidden":640,
            "decoder_layers":2,"cache_channel_shape":[1,24,56,1024],"cache_time_shape":[1,24,1024,8],"num_prompts":128,
            "default_prompt_id":101,"prompt_dictionary":["auto":101,"en-US":0,"nl-NL":1],"lang_tag_token_ids":[0,1]],options: [.sortedKeys])
    }
    static func tokens() -> Data {
        let pairs = (0..<13087).map { i in (String(i),"\"\(i)\":\"\(i == 0 ? "<en-US>" : i == 1 ? "<nl-NL>" : "piece\(i)")\"") }
        return Data(("{" + pairs.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: ",") + "}").utf8)
    }
    static func witness() throws -> LiveASRMetadataWitness {
        try LiveASRModelContract.validate(metadata: metadata(),tokenizer: tokens(),configuration: configuration)
    }
    static func description(_ role: LiveASRNativeDescription.Role) -> LiveASRNativeDescription {
        func array(_ name: String, _ kind: LiveASRNativeFeature.Kind, _ shape: [Int], _ type: LiveASRNativeFeature.ElementType = .float32) -> LiveASRNativeFeature {
            .init(name: name,kind: kind,shape: shape,bytesPerElement: type.byteWidth,elementType: type)
        }
        let token = [array("token",.input,[1,1],.int32),array("token_length",.input,[1],.int32),
                     array("h_in",.input,[2,1,640]),array("c_in",.input,[2,1,640])]
        let state = [array("h_out",.output,[2,1,640]),array("c_out",.output,[2,1,640])]
        let logits = array("logits",.output,[1,1,1,13088])
        let features: [LiveASRNativeFeature]
        switch role {
        case .encoder:
            features = [array("mel",.input,[1,128,121]),array("mel_length",.input,[1],.int32),array("prompt_id",.input,[1],.int32),
                        array("cache_len",.input,[1],.int32),array("cache_len_out",.output,[1],.int32),
                        array("cache_channel",.state,[1,24,56,1024],.float16),array("cache_time",.state,[1,24,1024,8],.float16),
                        array("encoded",.output,[1,1024,14]),array("encoder_proj",.output,[1,14,640])]
        case .decoder: features = token + state + [array("decoder_out",.output,[1,640,1])]
        case .joint: features = [array("encoder",.input,[1,1024,1]),array("decoder",.input,[1,640,1]),logits]
        case .decoderJoint: features = token + state + [array("encoder",.input,[1,1024,1]),logits]
        case .decoderJointArgmax: features = token + state + [array("encoder",.input,[1,1024,1]),array("token_id",.output,[1],.int32)]
        case .decoderJointNoEncProj: features = token + state + [array("encoder_proj",.input,[1,1,640]),logits]
        case .jointNoEncProjBatched: features = [array("encoder_proj",.input,[1,4,640]),array("decoder",.input,[1,640,1]),array("logits",.output,[1,4,1,13088],.float16)]
        }
        return .init(role: role,features: features)
    }
    static func replacing(_ feature: LiveASRNativeFeature, in role: LiveASRNativeDescription.Role) -> LiveASRNativeDescription {
        var features = description(role).features.filter { $0.name != feature.name || $0.kind != feature.kind }
        features.append(feature); return .init(role: role,features: features)
    }
    let root: URL; let source: URL; let staging: URL
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/native-asr-fixture-\(UUID())")
        source = root.appendingPathComponent("source"); staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: source,withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging,withIntermediateDirectories: false,attributes: [.posixPermissions:0o700])
        try Self.metadata().write(to: source.appendingPathComponent("metadata.json")); try Self.tokens().write(to: source.appendingPathComponent("tokenizer.json"))
        for name in ["encoder","decoder","joint","preprocessor"] {
            let directory = source.appendingPathComponent(name + ".mlmodelc")
            try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: false)
            try Data("fixture-\(name)".utf8).write(to: directory.appendingPathComponent("model.mil"))
        }
        let weights = source.appendingPathComponent("encoder.mlmodelc/weights")
        try FileManager.default.createDirectory(at: weights,withIntermediateDirectories: false)
        try Data([1,2,3]).write(to: weights.appendingPathComponent("weight.bin"))
    }
    func assets() throws -> LiveASRModelAssets {
        try .init(sourceDirectory: source,identity: Self.configuration.identity!,language: .auto,chunkMs: 1120,budget: .init(),testingStagingDirectory: staging)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
private actor ASRNativeProbe {
    private(set) var requests: [LiveASRNativeLoadRequest] = []
    private(set) var entered = false
    private var waiter: CheckedContinuation<Void,Never>?
    private var released = false
    func hold() async { entered = true; if !released { await withCheckedContinuation { waiter = $0 } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
    func construct(_ request: LiveASRNativeLoadRequest) -> any NemotronDecoderMaking { requests.append(request); return FixtureFactory() }
}
private func nativeASREventually(_ predicate: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while ContinuousClock.now < deadline { if await predicate() { return true }; try? await Task.sleep(for: .milliseconds(2)) }
    return await predicate()
}

@Suite struct LiveASRNativeTests {
    @Test(arguments: ["encoded-width","encoded-half","encoded-rank","projection-width","projection-half"])
    func actualSdkEncoderBuffersRejectDescriptionShapesAndTypesThatOverrunThem(mode: String) throws {
        let feature: LiveASRNativeFeature
        switch mode {
        case "encoded-width": feature = .init(name: "encoded",kind: .output,shape: [1,2048,14],bytesPerElement: 4)
        case "encoded-half": feature = .init(name: "encoded",kind: .output,shape: [1,1024,14],bytesPerElement: 2)
        case "encoded-rank": feature = .init(name: "encoded",kind: .output,shape: [1,1024],bytesPerElement: 4)
        case "projection-width": feature = .init(name: "encoder_proj",kind: .output,shape: [1,14,1280],bytesPerElement: 4)
        default: feature = .init(name: "encoder_proj",kind: .output,shape: [1,14,640],bytesPerElement: 2)
        }
        #expect(throws: LiveASRAssetError.self) {
            try LiveASRNativeConfiguration.validate([NativeASRFixture.replacing(feature,in: .encoder)],metadata: NativeASRFixture.witness(),chunkMs: 1120)
        }
    }

    @Test(arguments: ["encoded-int32","scalar-prompt","missing-encoded","decoder-half","decoder-width","logits-half","logits-size","batch-logits-short","batch-type","token-type"])
    func semanticContractMatchesEveryPinnedSdkPointerAndRequiredFeature(mode: String) throws {
        var role = LiveASRNativeDescription.Role.encoder
        let feature: LiveASRNativeFeature
        switch mode {
        case "encoded-int32": feature = .init(name: "encoded",kind: .output,shape: [1,1024,14],bytesPerElement: 4,elementType: .int32)
        case "scalar-prompt": feature = .init(name: "prompt_id",kind: .input,shape: [1],bytesPerElement: 8,elementType: .int64,isMultiArray: false)
        case "missing-encoded": feature = .init(name: "renamed",kind: .output,shape: [1,1024,14],bytesPerElement: 4)
        case "decoder-half": role = .decoder; feature = .init(name: "decoder_out",kind: .output,shape: [1,640,1],bytesPerElement: 2)
        case "decoder-width": role = .decoder; feature = .init(name: "decoder_out",kind: .output,shape: [1,1280,1],bytesPerElement: 4)
        case "logits-half": role = .joint; feature = .init(name: "logits",kind: .output,shape: [1,1,1,13088],bytesPerElement: 2)
        case "logits-size": role = .joint; feature = .init(name: "logits",kind: .output,shape: [1,1,1,13089],bytesPerElement: 4)
        case "batch-logits-short": role = .jointNoEncProjBatched; feature = .init(name: "logits",kind: .output,shape: [1,1,1,13088],bytesPerElement: 4)
        case "batch-type": role = .jointNoEncProjBatched; feature = .init(name: "logits",kind: .output,shape: [1,4,1,13088],bytesPerElement: 4,elementType: .int32)
        default: role = .decoder; feature = .init(name: "token",kind: .input,shape: [1,1],bytesPerElement: 4,elementType: .float32)
        }
        var description = NativeASRFixture.replacing(feature,in: role)
        if mode == "missing-encoded" { description = .init(role: role,features: description.features.filter { $0.name != "encoded" }) }
        #expect(throws: LiveASRAssetError.self) {
            try LiveASRNativeConfiguration.validate([description],metadata: NativeASRFixture.witness(),chunkMs: 1120)
        }
    }

    @Test(arguments: ["state-huge","state-negative","state-mismatch","output-overflow","batch","type","alternatives"])
    func descriptionBoundsProtectEveryNativeAllocationSurface(mode: String) throws {
        var feature = LiveASRNativeFeature(name: "cache_channel",kind: .state,shape: [1,24,56,1024],bytesPerElement: 2)
        var role = LiveASRNativeDescription.Role.encoder
        switch mode {
        case "state-huge": feature = .init(name: "cache_channel",kind: .state,shape: [1,24,Int.max,1024],bytesPerElement: 2)
        case "state-negative": feature = .init(name: "cache_channel",kind: .state,shape: [1,24,-1,1024],bytesPerElement: 2)
        case "state-mismatch": feature = .init(name: "cache_channel",kind: .state,shape: [1,24,42,1024],bytesPerElement: 2)
        case "output-overflow": feature = .init(name: "output",kind: .output,shape: [Int.max,Int.max],bytesPerElement: 4)
        case "batch": role = .jointNoEncProjBatched; feature = .init(name: "encoder_proj",kind: .input,shape: [1,33,1024],bytesPerElement: 4)
        case "type": feature = .init(name: "cache_channel",kind: .state,shape: [1,24,56,1024],bytesPerElement: 1)
        default: feature = .init(name: "cache_channel",kind: .state,shape: [1,24,56,1024],bytesPerElement: 2,alternativeShapes: [[1,24,Int.max,1024]])
        }
        #expect(throws: LiveASRAssetError.self) {
            try LiveASRNativeConfiguration.validate([NativeASRFixture.replacing(feature,in: role)],metadata: NativeASRFixture.witness(),chunkMs: 1120)
        }
    }

    @Test func validTypedDescriptionPreservesMetadataAndExplicitComputePolicy() throws {
        let roles: [LiveASRNativeDescription.Role] = [.encoder,.decoder,.joint,.decoderJoint,.decoderJointArgmax,.decoderJointNoEncProj,.jointNoEncProjBatched]
        try LiveASRNativeConfiguration.validate(roles.map(NativeASRFixture.description),metadata: NativeASRFixture.witness(),chunkMs: 1120)
        let policy = try LiveASRNativeConfiguration.policy(NativeASRFixture.configuration)
        #expect(policy.computeUnits == .cpuAndNeuralEngine && !policy.allowLowPrecisionGPUAccumulation)
    }

    @Test func missingIdentityAndExperimentalEnvironmentFailBeforeNativeConstruction() async throws {
        let probe = ASRNativeProbe()
        await #expect(throws: LiveASRAssetError.invalidConfiguration) {
            _ = try await LiveASRNativeLoader.load(.init(language: .auto,modelDirectory: "/missing"),environment: [:],constructor: { await probe.construct($0) })
        }
        await #expect(throws: LiveASRAssetError.invalidConfiguration) {
            _ = try await LiveASRNativeLoader.load(NativeASRFixture.configuration,environment: ["FLUIDAUDIO_JOINT_BATCHED_CU":"ALL"],
                constructor: { await probe.construct($0) })
        }
        #expect(await probe.requests.isEmpty)
    }

    @Test(arguments: [false,true])
    func actualLoaderUsesOnlyThePrivateWitnessAndRechecksHeldConstructionBoundary(replace: Bool) async throws {
        let f = try NativeASRFixture(); defer { f.remove() }
        let assets = try f.assets(), owner = UUID(), probe = ASRNativeProbe()
        try #require(assets.bind(to: owner)); try await assets.prepare(owner: owner)
        let loading = Task {
            try await LiveASRNativeLoader.load(assets.configuration,testingStagingDirectory: f.staging,environment: [:],
                beforeConstruction: { await probe.hold() },constructor: { await probe.construct($0) })
        }
        guard await nativeASREventually({ await probe.entered }) else {
            loading.cancel(); await probe.release(); _ = await loading.result; await assets.retire(owner: owner)?.value; Issue.record("loader not held"); return
        }
        let directory = URL(fileURLWithPath: assets.configuration.modelDirectory)
        do {
            if replace {
                try FileManager.default.moveItem(at: directory,to: f.staging.appendingPathComponent("original-moved"))
                try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: false)
            } else { try FileManager.default.removeItem(at: f.source) }
            await probe.release()
            let result = await loading.result
            if replace {
                if case .success = result { Issue.record("replacement reached constructor") }
                #expect(await probe.requests.isEmpty)
            } else {
                _ = try result.get()
                let request = try #require(await probe.requests.first)
                #expect(try request.snapshot.validateCurrentPath().path == directory.path)
                #expect(request.policy.computeUnits == .cpuAndNeuralEngine)
                #expect(request.snapshot.fingerprint == NativeASRFixture.fingerprint)
            }
        } catch {
            loading.cancel(); await probe.release(); _ = await loading.result; await assets.retire(owner: owner)?.value; throw error
        }
        await assets.retire(owner: owner)?.value
    }
}
