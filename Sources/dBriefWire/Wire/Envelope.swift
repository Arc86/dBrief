import Foundation

public enum MLChannel: String, Sendable, Codable {
    case plugin     // WhisperKit + SpeakerKit + MLX state stream
    case parakeet   // Parakeet state stream
}

public enum MLRequest: Sendable, Codable {
    /// `unloadAfter: false` keeps the Whisper/SpeakerKit models resident for the
    /// next call — used by segmented (>30 min) recordings so each 30-min part
    /// doesn't pay a full model reload; the last part passes `true`.
    case transcribe(path: String, initialPrompt: String?, config: WhisperRuntimeConfig, safeMode: Bool, unloadAfter: Bool)
    case diarize(path: String)
    case diarizeWithEmbeddings(path: String)
    case analyze(text: String, outputLanguage: OutputLanguage, customVocabulary: String, guidance: InsightsGuidance?)
    case analyzeStream(text: String, outputLanguage: OutputLanguage, customVocabulary: String, guidance: InsightsGuidance?)
    case chatStream(systemPrompt: String, userMessage: String)
    case parakeetTranscribe(path: String, modelVariant: String, diarize: Bool)
    case synthesizeSpeech(text: String, outputPath: String, voice: String?, language: String?, instruction: String?, model: String?, engine: String?)
    case prepareModels
    case downloadWhisper(config: WhisperRuntimeConfig)
    case prewarmWhisper(config: WhisperRuntimeConfig, refresh: Bool)
    case downloadLLM
    case downloadParakeet(variant: String)
    case isWhisperCached(name: String)
    case isLLMCached
    case isParakeetCached
    case fetchWhisperModels(repo: String)
    case purgeModels
    case purgeWhisper
    case purgeSpeakerKit
    case purgeQwen
    case purgeParakeet
    case memoryPressurePurge
    case forceUnload
    case cancel
}

public enum MLEvent: Sendable, Codable {
    case state(LocalAIPluginState)              // progress, carried per-channel
    case token(String)                          // one chunk of a streaming response
    case transcriptionResult(TranscriptionResult)
    case diarizeResult([DiarizedTurn])
    case diarizeWithEmbeddingsResult(turns: [DiarizedTurn], embeddings: [String: [Float]])
    case speechResult(SpeechSynthesisResult)
    case insightsResult(LocalInsightsResult)
    case boolResult(Bool)
    case stringsResult([String])
    case voidResult                             // terminal success for no-value ops
    case error(WireError)                       // terminal thrown (non-crash) error
    case finished                               // terminal marker for streaming ops
}

public struct RequestEnvelope: Sendable, Codable {
    public let id: UUID
    public let request: MLRequest
    public init(id: UUID, request: MLRequest) {
        self.id = id
        self.request = request
    }
}

public struct EventEnvelope: Sendable, Codable {
    public let id: UUID
    public let channel: MLChannel
    public let event: MLEvent
    public init(id: UUID, channel: MLChannel, event: MLEvent) {
        self.id = id
        self.channel = channel
        self.event = event
    }
}

public struct WireError: Sendable, Codable, Error {
    public enum Kind: String, Sendable, Codable {
        case transcriptionTimeout
        case modelLoadTimeout
        case insufficientMemory
        case audioLoadFailed
        case diarizationFailed
        case generic
    }
    public let kind: Kind
    public let message: String
    public let model: String?
    public let requiredGB: String?

    public init(kind: Kind, message: String, model: String? = nil, requiredGB: String? = nil) {
        self.kind = kind
        self.message = message
        self.model = model
        self.requiredGB = requiredGB
    }
}

extension WireError: LocalizedError {
    /// Surface the real `message` (and memory hint) instead of the generic
    /// "operation couldn't be completed (… error 1.)" Foundation default.
    public var errorDescription: String? {
        if kind == .insufficientMemory, let requiredGB {
            return "\(message) (needs ~\(requiredGB) GB)"
        }
        return message
    }
}
