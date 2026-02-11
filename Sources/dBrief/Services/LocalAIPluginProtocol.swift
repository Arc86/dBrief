import Foundation

enum DownloadStage: Sendable {
    case whisperModel
    case llmModel
}

enum LocalAIPluginState: Sendable {
    case idle
    case downloading(progress: Double?, stage: DownloadStage)
    case transcribing
    case analyzing
}

protocol LocalAIPluginProtocol: Sendable {
    var stateStream: AsyncStream<LocalAIPluginState> { get }

    func transcribe(fileURL: URL, initialPrompt: String?) async throws -> TranscriptionResult
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
