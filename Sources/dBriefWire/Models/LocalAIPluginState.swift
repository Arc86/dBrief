import Foundation

public enum DownloadStage: String, Sendable, Codable {
    case whisperModel         // Downloading model weights from HuggingFace
    case whisperModelLoading  // Model cached locally, now loading into memory
    case llmModelPreparing    // Resolving the local cache / remote model files
    case llmModel
    case llmModelLoading      // Download complete; loading weights into memory
    case speakerKitModel
    case parakeetModel        // Downloading Parakeet CoreML model from HuggingFace
    case parakeetModelLoading // Cached Parakeet model loading into memory
    case ttsModel             // Downloading TTSKit (Qwen3-TTS) model from HuggingFace
    case ttsModelLoading      // Cached TTS model loading into memory
    case kokoroTTSModel       // Downloading FluidAudio Kokoro CoreML model from HuggingFace
    case kokoroTTSModelLoading // Cached Kokoro model loading into memory
    case embeddingModel       // Downloading EmbeddingGemma (transcript-chat search model)
}

public enum LocalAIPluginState: Sendable, Codable {
    case idle
    case downloading(progress: Double?, stage: DownloadStage)
    case transcribing
    case newSegments([LiveTranscriptSegment])
    case diarizing
    case analyzing
    /// Long-transcript (map-reduce) analysis. `index` is 1-based; `index == total + 1`
    /// means the combine (reduce) step is running.
    case analyzingPart(index: Int, total: Int)

    private enum Kind: String, Codable {
        case idle, downloading, transcribing, newSegments, diarizing, analyzing, analyzingPart
    }
    private enum CodingKeys: String, CodingKey { case kind, progress, stage, segments, index, total }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .idle: self = .idle
        case .transcribing: self = .transcribing
        case .diarizing: self = .diarizing
        case .analyzing: self = .analyzing
        case .downloading:
            self = .downloading(
                progress: try c.decodeIfPresent(Double.self, forKey: .progress),
                stage: try c.decode(DownloadStage.self, forKey: .stage)
            )
        case .newSegments:
            self = .newSegments(try c.decode([LiveTranscriptSegment].self, forKey: .segments))
        case .analyzingPart:
            self = .analyzingPart(index: try c.decode(Int.self, forKey: .index),
                                  total: try c.decode(Int.self, forKey: .total))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle: try c.encode(Kind.idle, forKey: .kind)
        case .transcribing: try c.encode(Kind.transcribing, forKey: .kind)
        case .diarizing: try c.encode(Kind.diarizing, forKey: .kind)
        case .analyzing: try c.encode(Kind.analyzing, forKey: .kind)
        case let .downloading(progress, stage):
            try c.encode(Kind.downloading, forKey: .kind)
            try c.encodeIfPresent(progress, forKey: .progress)
            try c.encode(stage, forKey: .stage)
        case let .newSegments(segments):
            try c.encode(Kind.newSegments, forKey: .kind)
            try c.encode(segments, forKey: .segments)
        case let .analyzingPart(index, total):
            try c.encode(Kind.analyzingPart, forKey: .kind)
            try c.encode(index, forKey: .index)
            try c.encode(total, forKey: .total)
        }
    }
}
