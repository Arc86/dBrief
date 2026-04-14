import Foundation

enum DownloadStage: Sendable {
    case whisperModel         // Downloading model weights from HuggingFace
    case whisperModelLoading  // Model cached locally, now loading into memory
    case llmModel
    case speakerKitModel
}

enum LocalAIPluginState: Sendable {
    case idle
    case downloading(progress: Double?, stage: DownloadStage)
    case transcribing
    case newSegments([LiveTranscriptSegment])
    case diarizing
    case analyzing
}

/// Runtime configuration passed to WhisperKit for each transcription call.
/// Allows the user's model and GPU settings to take effect without restarting the app.
struct WhisperRuntimeConfig: Sendable, Equatable {
    let modelName: String
    let language: String?
    let diarizationEnabled: Bool

    static let `default` = WhisperRuntimeConfig(
        modelName: "openai_whisper-small",
        language: nil,
        diarizationEnabled: false
    )
}

protocol LocalAIPluginProtocol: Sendable {
    var stateStream: AsyncStream<LocalAIPluginState> { get }

    func transcribe(fileURL: URL, initialPrompt: String?, whisperConfig: WhisperRuntimeConfig) async throws -> TranscriptionResult
    func analyzeTranscriptStream(
        _ text: String,
        outputLanguage: AppSettings.OutputLanguage
    ) async -> AsyncThrowingStream<String, Error>
    func analyzeTranscript(
        _ text: String,
        outputLanguage: AppSettings.OutputLanguage
    ) async throws -> LocalInsightsResult
    func copyToClipboard(transcript: String, insights: LocalInsightsResult) async -> String
    func prepareModelsIfNeeded() async
    func purgeModels() async throws
}
