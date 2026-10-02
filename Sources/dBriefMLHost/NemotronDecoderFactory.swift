import CryptoKit
import FluidAudio
import Foundation

/// One immutable model bundle is retained while each returned manager owns fresh
/// decoder/cache/MLState buffers. Loading never uses the runtime's downloader.
struct NemotronDecoderFactory: NemotronDecoderMaking {
    let modelFingerprint: String?
    private let shared: SharedNemotronMultilingualModels

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
        return Self(modelFingerprint: fingerprint, shared: shared)
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
        await manager.setLanguage(Self.hint(configuration.language, prompts: shared.config.promptDictionary))
        await manager.setPartialCallback(partial)
        return NemotronNativeDecoder(manager: manager, chunkSamples: shared.config.chunkSamples)
    }
}

private actor NemotronNativeDecoder: NemotronStreamingDecoder {
    private let manager: StreamingNemotronMultilingualAsrManager
    private let chunkSamples: Int
    private var accepted: Int64 = 0
    init(manager: StreamingNemotronMultilingualAsrManager, chunkSamples: Int) {
        self.manager = manager; self.chunkSamples = chunkSamples
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
