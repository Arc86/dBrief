import CryptoKit
import FluidAudio
import Foundation
import dBriefWire

/// One immutable model bundle is retained while each returned manager owns fresh
/// decoder/cache/MLState buffers. Loading never uses the runtime's downloader.
struct NemotronDecoderFactory: NemotronDecoderMaking {
    let modelFingerprint: String?
    private let shared: SharedNemotronMultilingualModels
    private let liveSnapshot: LiveASRReadOnlySnapshot?

    static func validateMetadata(at directory: URL, configuration: NemotronDecoderConfiguration) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("metadata.json"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["sample_rate"] as? Int == 16000,
              let melFrames = json["chunk_mel_frames"] as? Int, melFrames == configuration.chunkMs / 10,
              (json["chunk_ms"] as? Int ?? melFrames * 10) == configuration.chunkMs,
              json["vocab_size"] as? Int == 13087,
              let prompts = json["prompt_dictionary"] as? [String: Int] else {
            throw NemotronSessionError.invalidConfiguration
        }
        if configuration.language != .auto, hint(configuration.language, prompts: prompts) == nil {
            throw NemotronSessionError.invalidConfiguration
        }
    }

    static func load(from directory: URL, configuration: NemotronDecoderConfiguration) async throws -> Self {
        try validateMetadata(at: directory, configuration: configuration)
        let fingerprint = try fingerprint(directory)
        let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: directory)
        try Task.checkCancellation()
        return Self(modelFingerprint: fingerprint, shared: shared, liveSnapshot: nil)
    }

    /// Production live loading accepts only the parent's private, validated
    /// compiled snapshot. Its witness survives the SDK's asynchronous URL opens.
    static func loadOwned(_ request: LiveASRNativeLoadRequest) async throws -> Self {
        let snapshot = request.snapshot, configuration = snapshot.configuration
        let policy = try LiveASRNativeConfiguration.policy(configuration)
        guard policy.computeUnits == request.policy.computeUnits,
              policy.allowLowPrecisionGPUAccumulation == request.policy.allowLowPrecisionGPUAccumulation else {
            throw LiveASRAssetError.invalidConfiguration
        }
        try Task.checkCancellation()
        let directory = try snapshot.validateCurrentPath()
        let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: directory,configuration: policy.modelConfiguration())
        try Task.checkCancellation()
        _ = try snapshot.validateCurrentPath()
        let config = shared.config, metadata = snapshot.metadata
        guard config.sampleRate == 16000, config.melFeatures == 128, config.chunkMelFrames == configuration.chunkMs/10,
              config.chunkMs == configuration.chunkMs, config.preEncodeCache == 9, config.totalMelFrames == configuration.chunkMs/10+9,
              config.vocabSize == 13087, config.blankIdx == 13087, config.encoderDim == 1024,
              config.decoderHidden == 640, config.decoderLayers == 2, config.numPrompts == 128,
              config.cacheChannelShape == [1,24,metadata.channelCacheFrames,1024], config.cacheTimeShape == [1,24,1024,8],
              (0..<128).contains(config.defaultPromptId), config.promptDictionary["auto"] == config.defaultPromptId,
              !config.promptDictionary.isEmpty, config.promptDictionary.count <= 128,
              config.promptDictionary.values.allSatisfy({ (0..<128).contains($0) }),
              config.promptId(forLanguage: metadata.languageHint) == metadata.promptID,
              !config.langTagTokenIds.isEmpty, config.langTagTokenIds.count <= 128,
              config.langTagTokenIds.allSatisfy({ (0..<13087).contains($0) }) else { throw LiveASRAssetError.invalidAsset }
        var descriptions = [try LiveASRNativeConfiguration.description(shared.encoder,role: .encoder)]
        let others = [(LiveASRNativeDescription.Role.decoder,shared.decoder),(.joint,shared.joint),
                      (.decoderJoint,shared.decoderJoint),(.decoderJointArgmax,shared.decoderJointArgmax),
                      (.decoderJointNoEncProj,shared.decoderJointNoEncProj),(.jointNoEncProjBatched,shared.jointNoEncProjBatched)]
        for (role,model) in others {
            if let model { descriptions.append(try LiveASRNativeConfiguration.description(model,role: role)) }
        }
        try LiveASRNativeConfiguration.validate(descriptions,metadata: metadata,chunkMs: configuration.chunkMs)
        return Self(modelFingerprint: snapshot.fingerprint,shared: shared,liveSnapshot: snapshot)
    }

    private static func fingerprint(_ directory: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw NemotronSessionError.invalidConfiguration
        }
        var files: [URL] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw NemotronSessionError.invalidConfiguration }
            if values.isRegularFile == true { files.append(file) }
        }
        var tree = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let name = String(file.path.dropFirst(directory.path.count))
            tree.update(data: Data(name.utf8)); tree.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation(); hash.update(data: bytes)
            }
            tree.update(data: Data(hash.finalize()))
        }
        return tree.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hint(_ language: NemotronDecoderConfiguration.Language, prompts: [String: Int]) -> String? {
        if language == .auto { return nil }
        if prompts[language.rawValue] != nil { return language.rawValue }
        return prompts.keys.sorted().first { $0.replacingOccurrences(of: "_", with: "-")
            .lowercased().split(separator: "-").first == Substring(language.rawValue) }
    }

    func makeDecoder(configuration: NemotronDecoderConfiguration,
                     partial: @escaping @Sendable (String) -> Void) async throws -> any NemotronStreamingDecoder {
        if let liveSnapshot {
            guard liveSnapshot.configuration.language.rawValue == configuration.language.rawValue,
                  liveSnapshot.configuration.chunkMs == configuration.chunkMs else { throw NemotronSessionError.invalidConfiguration }
            _ = try liveSnapshot.validateCurrentPath()
        }
        guard shared.config.chunkMs == configuration.chunkMs,
              configuration.language == .auto || Self.hint(configuration.language, prompts: shared.config.promptDictionary) != nil else {
            throw NemotronSessionError.invalidConfiguration
        }
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadFromShared(shared)
        try Task.checkCancellation()
        // Forced prefix is off by default and explicitly stays off. Hint setup
        // cannot fall back to auto silently for an unsupported language.
        await manager.setForcedPrefix(false)
        await manager.setLanguage(liveSnapshot?.metadata.languageHint ?? Self.hint(configuration.language, prompts: shared.config.promptDictionary))
        await manager.setPartialCallback(partial)
        return NemotronNativeDecoder(manager: manager, chunkSamples: shared.config.chunkSamples, liveSnapshot: liveSnapshot)
    }
}

private actor NemotronNativeDecoder: NemotronStreamingDecoder {
    private let manager: StreamingNemotronMultilingualAsrManager
    private let chunkSamples: Int
    private let liveSnapshot: LiveASRReadOnlySnapshot?
    private var accepted: Int64 = 0
    init(manager: StreamingNemotronMultilingualAsrManager, chunkSamples: Int, liveSnapshot: LiveASRReadOnlySnapshot?) {
        self.manager = manager; self.chunkSamples = chunkSamples; self.liveSnapshot = liveSnapshot
    }
    func process(samples: [Float]) async throws -> NemotronDecoderProgress {
        _ = try await manager.process(samples: samples)
        accepted += Int64(samples.count)
        // Only a successful drain can use chunkCount. Failed inference can
        // increment it before throwing; the session discards that utterance.
        // Pinned blank-rescue code restores counters after its trial decode.
        let consumed = Int64(await manager.chunkCount) * Int64(chunkSamples)
        guard consumed <= accepted else { throw NemotronSessionError.invalidAccounting }
        return .init(consumedSamples: consumed, heldSamples: accepted - consumed)
    }
    func finish() async throws -> NemotronDecoderOutput {
        let result = try await manager.finishWithTokenTimings()
        return .init(text: result.text, timings: result.timings.map {
            .init(token: $0.token, startSeconds: $0.startTime, endSeconds: $0.endTime)
        })
    }
}
