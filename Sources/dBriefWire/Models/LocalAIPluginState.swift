import Foundation

public enum DownloadStage: String, Sendable, Codable {
    case whisperModel         // Downloading model weights from HuggingFace
    case whisperModelLoading  // Model cached locally, now loading into memory
    case llmModel
    case speakerKitModel
    case parakeetModel        // Downloading Parakeet CoreML model from HuggingFace
    case parakeetModelLoading // Cached Parakeet model loading into memory
}

public enum LocalAIPluginState: Sendable, Codable {
    case idle
    case downloading(progress: Double?, stage: DownloadStage)
    case transcribing
    case newSegments([LiveTranscriptSegment])
    case diarizing
    case analyzing

    private enum Kind: String, Codable {
        case idle, downloading, transcribing, newSegments, diarizing, analyzing
    }
    private enum CodingKeys: String, CodingKey { case kind, progress, stage, segments }

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
        }
    }
}
