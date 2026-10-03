import Foundation
import Testing
@testable import dBriefWire
@testable import dBrief

/// Hand-framed independently with Python hashlib/struct; no production hash
/// routine generates an expected value for these fixtures.
struct ASRAssetsFixture: Sendable {
    static let fingerprint = "5b62fde7e92de6139cb9992d20b48f492c3704d48c2bbc79d51b6b200e369542"
    let root: URL
    let source: URL
    let staging: URL
    static var metadata: [String: Any] {
        ["sample_rate":16000,"mel_features":128,"chunk_mel_frames":112,"chunk_ms":1120,
         "pre_encode_cache":9,"total_mel_frames":121,"vocab_size":13087,"blank_idx":13087,
         "encoder_dim":1024,"decoder_hidden":640,"decoder_layers":2,
         "cache_channel_shape":[1,24,56,1024],"cache_time_shape":[1,24,1024,8],
         "num_prompts":128,"default_prompt_id":101,
         "prompt_dictionary":["auto":101,"en-US":0,"nl-NL":1],"lang_tag_token_ids":[0,1]]
    }
    static func metadataData(_ value: [String: Any] = metadata) throws -> Data {
        try JSONSerialization.data(withJSONObject: value,options: [.sortedKeys])
    }
    static func tokenizer(omitting: Int? = nil, replacing: (Int,String)? = nil) -> Data {
        let entries = (0..<13087).filter { $0 != omitting }.map { i -> (String,String) in
            let piece = replacing?.0 == i ? replacing!.1 : (i == 0 ? "<en-US>" : i == 1 ? "<nl-NL>" : "piece\(i)")
            return (String(i),"\"\(i)\":\"\(piece)\"")
        }
        return Data(("{" + entries.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: ",") + "}").utf8)
    }
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/asr-owned-fixture-\(UUID())",isDirectory: true)
        source = root.appendingPathComponent("source"); staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
        try FileManager.default.createDirectory(at: source,withIntermediateDirectories: true)
        try Self.metadataData().write(to: source.appendingPathComponent("metadata.json"))
        try Self.tokenizer().write(to: source.appendingPathComponent("tokenizer.json"))
        for name in ["encoder","decoder","joint","preprocessor"] {
            let model = source.appendingPathComponent(name + ".mlmodelc")
            try FileManager.default.createDirectory(at: model,withIntermediateDirectories: false)
            try Data("fixture-\(name)".utf8).write(to: model.appendingPathComponent("model.mil"))
        }
        let weights = source.appendingPathComponent("encoder.mlmodelc/weights")
        try FileManager.default.createDirectory(at: weights,withIntermediateDirectories: false)
        try Data([1,2,3]).write(to: weights.appendingPathComponent("weight.bin"))
    }
    static func identity(fingerprint: String = Self.fingerprint, units: LiveASRIdentity.ComputeUnits = .cpuAndNeuralEngine) -> LiveASRIdentity {
        .init(modelRevision: "fixture-asr",modelFingerprint: fingerprint,runtimeRevision: LiveASRIdentity.currentRuntimeRevision,computeUnits: units)
    }
    static func configuration(identity: LiveASRIdentity? = Self.identity(), language: LiveASRConfiguration.Language = .auto,
                              path: String = "/private/tmp/frozen-native-assets") -> LiveASRConfiguration {
        .init(language: language,chunkMs: 1120,modelDirectory: path,identity: identity)
    }
    func assets(budget: LiveASRStagingBudget = .init(), limits: LiveASRModelAssets.Limits = .init(),
                probe: LiveASRModelAssets.Probe? = nil, identity: LiveASRIdentity = Self.identity()) throws -> LiveASRModelAssets {
        try .init(sourceDirectory: source,identity: identity,language: .auto,chunkMs: 1120,budget: budget,
                  testingStagingDirectory: staging,limits: limits,probe: probe)
    }
    var staged: [String] { (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [] }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct LiveASRContractTests {
    @Test func identityRoundTripAndEpochRevisionAreBoundWithoutChangingLegacyFixtures() throws {
        let config = ASRAssetsFixture.configuration()
        #expect(try JSONDecoder().decode(LiveASRConfiguration.self,from: JSONEncoder().encode(config)) == config)
        let legacy = try JSONDecoder().decode(LiveASRConfiguration.self,from: Data("{\"language\":\"auto\",\"chunkMs\":1120,\"modelDirectory\":\"/legacy\"}".utf8))
        #expect(legacy.identity == nil && legacy.isValid)
        let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
        let wrong = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "other",language: "auto",meetingOriginNanoseconds: nil)
        #expect(!LiveSessionBegin(identity: identity,configuration: config,epochs: [wrong]).isValid)
        let right = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture-asr",language: "auto",meetingOriginNanoseconds: nil)
        #expect(LiveSessionBegin(identity: identity,configuration: config,epochs: [right]).isValid)
    }

    @Test(arguments: ["/private/tmp//asset","/private/tmp/../asset","/private/tmp/./asset","/private/tmp/asset\n"])
    func configuredPathsCannotAliasLexicalOwners(path: String) {
        #expect(!ASRAssetsFixture.configuration(path: path).isValid)
    }

    @Test func strictWitnessSelectsFrozenHintsAndAllowsOnlyDocumentedOptionalChunkDuration() throws {
        let tokens = ASRAssetsFixture.tokenizer()
        for (language,hint,prompt) in [(LiveASRConfiguration.Language.auto,Optional<String>.none,101),(.en,"en-US",0),(.nl,"nl-NL",1)] {
            let witness = try LiveASRModelContract.validate(metadata: ASRAssetsFixture.metadataData(),tokenizer: tokens,
                configuration: ASRAssetsFixture.configuration(language: language))
            #expect(witness.languageHint == hint && witness.promptID == prompt)
        }
        var metadata = ASRAssetsFixture.metadata; metadata.removeValue(forKey: "chunk_ms")
        _ = try LiveASRModelContract.validate(metadata: ASRAssetsFixture.metadataData(metadata),tokenizer: tokens,
            configuration: ASRAssetsFixture.configuration())
    }

    @Test(arguments: ["missing","boolean","negative","overflow","mel","total","prompt","blank","tags","shape","auto"])
    func unsafeMetadataFailsBeforeNativeAllocation(mode: String) throws {
        var metadata = ASRAssetsFixture.metadata
        switch mode {
        case "missing": metadata.removeValue(forKey: "decoder_hidden")
        case "boolean": metadata["num_prompts"] = true
        case "negative": metadata["decoder_layers"] = -2
        case "overflow": metadata["cache_channel_shape"] = [1,24,Int.max,1024]
        case "mel": metadata["chunk_mel_frames"] = 224
        case "total": metadata["total_mel_frames"] = 1
        case "prompt": metadata["prompt_dictionary"] = ["auto":101,"en-US":Int.max,"nl-NL":1]
        case "blank": metadata["blank_idx"] = Int.max
        case "tags": metadata["lang_tag_token_ids"] = [0,13087]
        case "shape": metadata["cache_time_shape"] = [1,24,1024,-1]
        default: metadata["default_prompt_id"] = 1
        }
        #expect(throws: LiveASRAssetError.self) {
            _ = try LiveASRModelContract.validate(metadata: ASRAssetsFixture.metadataData(metadata),tokenizer: ASRAssetsFixture.tokenizer(),
                configuration: ASRAssetsFixture.configuration())
        }
    }

    @Test(arguments: ["wrong-type","missing","alias","duplicate","oversized","tag","extra"])
    func tokenizerCannotCollapseOrTrapItsVocabulary(mode: String) throws {
        var tokens = ASRAssetsFixture.tokenizer()
        if mode == "wrong-type" { tokens = Data("{\"0\":2}".utf8) }
        if mode == "missing" { tokens = ASRAssetsFixture.tokenizer(omitting: 1234) }
        if mode == "oversized" { tokens = ASRAssetsFixture.tokenizer(replacing: (12,String(repeating: "a",count: 4097))) }
        if mode == "tag" { tokens = ASRAssetsFixture.tokenizer(replacing: (1,"piece1")) }
        if ["alias","duplicate","extra"].contains(mode) {
            tokens.removeLast()
            tokens.append(Data((mode == "alias" ? ",\"01\":\"alias\"}" : mode == "duplicate" ? ",\"1\":\"duplicate\"}" : ",\"13088\":\"extra\"}").utf8))
        }
        #expect(throws: LiveASRAssetError.self) {
            _ = try LiveASRModelContract.validate(metadata: ASRAssetsFixture.metadataData(),tokenizer: tokens,
                configuration: ASRAssetsFixture.configuration())
        }
    }

    @Test func liveEnvironmentIsFilteredAfterMergingWithoutChangingOrdinaryRouting() {
        let inherited = ["FLUIDAUDIO_JOINT_BATCHED_CU":"ALL","KEEP":"first"]
        let extra = ["FLUIDAUDIO_ENABLE_SMART_SPECULATIVE":"1","KEEP":"second","DBRIEF_MLHOST_STUB":"1"]
        let live = LiveASRIdentity.environment(inherited: inherited,extra: extra,live: true)
        #expect(live == ["KEEP":"second","DBRIEF_MLHOST_STUB":"1"])
        #expect(LiveASRIdentity.environment(inherited: inherited,extra: extra,live: false)["FLUIDAUDIO_JOINT_BATCHED_CU"] == "ALL")
    }
}
