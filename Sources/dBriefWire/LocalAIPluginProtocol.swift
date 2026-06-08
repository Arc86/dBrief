import Foundation

public protocol LocalAIPluginProtocol: Sendable {
    var stateStream: AsyncStream<LocalAIPluginState> { get }

    func transcribe(fileURL: URL, initialPrompt: String?, whisperConfig: WhisperRuntimeConfig) async throws -> TranscriptionResult
    func analyzeTranscriptStream(
        _ text: String,
        outputLanguage: OutputLanguage
    ) async -> AsyncThrowingStream<String, Error>
    func analyzeTranscript(
        _ text: String,
        outputLanguage: OutputLanguage
    ) async throws -> LocalInsightsResult
    func copyToClipboard(transcript: String, insights: LocalInsightsResult) async -> String
    func prepareModelsIfNeeded() async
    func purgeModels() async throws
}
