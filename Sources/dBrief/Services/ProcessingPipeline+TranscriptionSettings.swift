import Foundation
import dBriefWire

extension ProcessingPipeline {
    /// One value snapshot for the entire segmented transcription and spelling
    /// pass. Settings/profile changes apply to the next pass, never later segments
    /// of an active pass. Preserve each engine's existing raw/effective policy.
    struct TranscriptionSettings: Sendable {
        let engine: AppSettings.TranscriptionEngine
        let language: String
        let whisper: WhisperRuntimeConfig
        let parakeetLanguage: String?
        let parakeetModelVariant: String
        let diarize: Bool
        let endpoint: Endpoint?
        let chunking: TranscriptionService.ChunkingConfiguration
        let cleanup: TranscriptionOptions
        let spelling: TranscriptSpellingService.Request
        let modelDisplayName: String
        let modelName: String?

        @MainActor init(settings: AppSettings) {
            engine = settings.effectiveTranscriptionEngine
            language = settings.effectiveTranscriptionLanguage
            whisper = settings.whisperRuntimeConfig
            parakeetLanguage = settings.transcriptionLanguage.isEmpty ? nil : settings.transcriptionLanguage
            parakeetModelVariant = settings.parakeetModelVariant
            diarize = settings.diarizationEnabled
            endpoint = settings.effectiveDefaultTranscriptionEndpoint
            chunking = .init(enabled: settings.remoteChunkingEnabled, maxUploadMB: settings.remoteChunkMaxUploadMB,
                             overlapSeconds: settings.remoteChunkOverlapSeconds, retryCount: settings.remoteChunkRetryCount)
            // Local CLI correction uses the configured chat fallback, as before.
            let spellingEngine = settings.effectiveAIEngine == .localCLI ? settings.chatFallbackEngine : settings.effectiveAIEngine
            spelling = .init(terms: settings.effectiveCustomVocabulary, engine: spellingEngine,
                             endpoint: settings.effectiveDefaultAIEndpoint)
            switch engine {
            case .appleSpeech:
                modelDisplayName = "Apple Speech"
                modelName = "Apple Speech"
            case .localWhisper:
                modelDisplayName = WhisperModelInfo.parse(whisper.modelName).displayName
                modelName = "\(whisper.modelName) (CoreML)"
            case .parakeetLocal:
                let model = ParakeetModelInfo.find(parakeetModelVariant)
                modelDisplayName = model.displayName
                modelName = "\(model.id) (CoreML)"
            case .remoteEndpoint:
                let name = endpoint?.modelName.trimmingCharacters(in: .whitespaces) ?? ""
                modelDisplayName = name.isEmpty ? "Remote Endpoint" : name
                modelName = endpoint.flatMap { TranscriptionService.modelName(for: $0) }
            }
            cleanup = .init(removeFillerWords: settings.effectiveRemoveFillerWords,
                            ignoredSegments: settings.effectiveIgnoredSegments, modelName: modelName)
        }
    }
}
