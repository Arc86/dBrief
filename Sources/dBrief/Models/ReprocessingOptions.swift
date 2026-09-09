import CryptoKit
import Foundation
import dBriefWire

enum ReprocessingOperation: String, Codable, Sendable, CaseIterable {
    case transcribe, analysis, speakers

    var title: String {
        switch self {
        case .transcribe: "Retranscribe"
        case .analysis: "Re-run AI analysis"
        case .speakers: "Detect speakers again"
        }
    }
    var displayName: String { title }
}

/// Editable while the sheet is open; the durable attempt stores its own value copy.
/// All execution inputs are frozen except credentials, which are resolved against
/// an exactly matching current destination before a request can be made.
struct ReprocessingOptions: Codable, Sendable {
    /// Present only on a successfully published result set.
    var completion: ProcessingCompletionStamp? = nil
    var operation: ReprocessingOperation
    var spokenLanguage: String
    var engine: AppSettings.TranscriptionEngine
    var whisperModelName: String
    var whisperComputeUnits: WhisperComputeUnits
    var parakeetModelVariant: String
    var diarizationEnabled: Bool
    var regenerateAI: Bool = true
    var speakerIdMode: AppSettings.SpeakerIdMode
    var transcriptionEndpoint: Endpoint?
    var aiEndpoint: Endpoint?
    var aiEngine: AppSettings.AIEngine
    var spellingEngine: AppSettings.AIEngine
    var outputLanguage: OutputLanguage
    var vocabulary: [String]
    var summaryPrompt: String
    var actionItemsPrompt: String
    var tagsPrompt: String
    var removeFillerWords: Bool
    var ignoredSegments: Set<String>
    var remoteChunkingEnabled: Bool
    var remoteChunkMaxUploadMB: Int
    var remoteChunkOverlapSeconds: Double
    var remoteChunkRetryCount: Int

    // A free-form shell command can contain credentials anywhere, so never persist
    // the command itself. Its digest also prevents resumed work from executing a
    // different command or timeout after Settings changes.
    private var localCLIConfigurationDigest: String

    @MainActor init(settings: AppSettings, operation: ReprocessingOperation) {
        self.operation = operation
        spokenLanguage = settings.effectiveTranscriptionLanguage
        engine = settings.effectiveTranscriptionEngine
        whisperModelName = settings.whisperModelName
        whisperComputeUnits = settings.whisperComputeUnits
        parakeetModelVariant = settings.parakeetModelVariant
        diarizationEnabled = settings.diarizationEnabled
        speakerIdMode = settings.speakerIdMode
        transcriptionEndpoint = Self.metadata(settings.effectiveDefaultTranscriptionEndpoint)
        aiEndpoint = Self.metadata(settings.effectiveDefaultAIEndpoint)
        aiEngine = settings.effectiveAIEngine
        spellingEngine = aiEngine == .localCLI ? settings.chatFallbackEngine : aiEngine
        outputLanguage = settings.outputLanguage
        vocabulary = settings.effectiveCustomVocabulary
        summaryPrompt = settings.effectiveSummaryPrompt
        actionItemsPrompt = settings.effectiveActionItemsPrompt
        tagsPrompt = settings.effectiveTagsPrompt
        removeFillerWords = settings.effectiveRemoveFillerWords
        ignoredSegments = settings.effectiveIgnoredSegments
        remoteChunkingEnabled = settings.remoteChunkingEnabled
        remoteChunkMaxUploadMB = settings.remoteChunkMaxUploadMB
        remoteChunkOverlapSeconds = settings.remoteChunkOverlapSeconds
        remoteChunkRetryCount = settings.remoteChunkRetryCount
        localCLIConfigurationDigest = Self.digest(settings.localCLIConfig)
    }

    var requiresTranscription: Bool { operation == .transcribe }
    var requiresSpeakers: Bool { operation == .speakers || (requiresTranscription && diarizationEnabled) }
    var requiresAnalysis: Bool { operation == .analysis || (requiresTranscription && regenerateAI) }
    var retainedAnalysisIsStale: Bool { requiresTranscription && !regenerateAI }

    enum ConfigurationError: LocalizedError {
        case endpointMissing(String)
        case endpointChanged(String)
        case cliChanged
        case unsupportedModel(String)
        case unsupportedLanguage(String)

        var errorDescription: String? {
            switch self {
            case .endpointMissing(let purpose): "The saved \(purpose) endpoint is unavailable. Restore its configuration to resume, or start a new attempt."
            case .endpointChanged(let name): "The endpoint ‘\(name)’ has changed since this attempt was saved. Restore its configuration to resume, or start a new attempt."
            case .cliChanged: "The Local CLI command or timeout has changed. Restore the saved configuration to resume, or start a new attempt."
            case .unsupportedModel(let reason), .unsupportedLanguage(let reason): reason
            }
        }
    }

    /// Validate capability constraints without downloading or changing a model.
    /// Model installation availability is checked by the selected backend at run time.
    func validate() throws {
        guard requiresTranscription else { return }
        if !spokenLanguage.isEmpty,
           spokenLanguage.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) == nil {
            throw ConfigurationError.unsupportedLanguage("Choose a spoken language code, or automatic detection.")
        }
        let isEnglish = spokenLanguage.isEmpty || spokenLanguage.lowercased().split(separator: "-").first == "en"
        switch engine {
        case .localWhisper:
            guard !whisperModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigurationError.unsupportedModel("Choose a Whisper model before retranscribing.")
            }
            if WhisperModelInfo.parse(whisperModelName).isEnglishOnly && !isEnglish {
                throw ConfigurationError.unsupportedLanguage("This Whisper model supports English only. Choose a multilingual model for this language.")
            }
        case .parakeetLocal:
            guard ParakeetModelInfo.variants.contains(where: { $0.id == parakeetModelVariant }) else {
                throw ConfigurationError.unsupportedModel("The saved Parakeet model is unavailable. Choose v2 or v3.")
            }
            if parakeetModelVariant == "v2" && !isEnglish {
                throw ConfigurationError.unsupportedLanguage("Parakeet v2 supports English only. Choose v3 for multilingual speech.")
            }
        case .appleSpeech, .remoteEndpoint: break
        }
    }

    @MainActor func transcriptionSettings(settings: AppSettings) throws -> ProcessingPipeline.TranscriptionSettings {
        try validate()
        let endpoint = engine == .remoteEndpoint
            ? try Self.resolve(transcriptionEndpoint, in: settings.transcriptionEndpoints, purpose: "transcription") : nil
        let spellingEndpoint = !vocabulary.isEmpty && spellingEngine == .remoteEndpoint
            ? try Self.resolve(aiEndpoint, in: settings.aiEndpoints, purpose: "vocabulary correction") : nil
        let language = spokenLanguage.isEmpty ? nil : spokenLanguage
        return .init(engine: engine, language: spokenLanguage,
            whisper: .init(modelName: whisperModelName, language: language,
                           diarizationEnabled: diarizationEnabled, computeUnits: whisperComputeUnits),
            parakeetLanguage: language, parakeetModelVariant: parakeetModelVariant,
            diarize: diarizationEnabled, endpoint: endpoint,
            chunking: .init(enabled: remoteChunkingEnabled, maxUploadMB: remoteChunkMaxUploadMB,
                            overlapSeconds: remoteChunkOverlapSeconds, retryCount: remoteChunkRetryCount),
            removeFillerWords: removeFillerWords, ignoredSegments: ignoredSegments,
            spelling: .init(terms: vocabulary, engine: spellingEngine, endpoint: spellingEndpoint))
    }

    struct AnalysisConfiguration: Sendable {
        var engine: AppSettings.AIEngine
        var endpoint: Endpoint?
        var outputLanguage: OutputLanguage
        var vocabulary: String
        var guidance: InsightsGuidance
        var localCLIConfig: LocalCLIConfig
    }

    @MainActor func analysisConfiguration(settings: AppSettings) throws -> AnalysisConfiguration {
        let endpoint = aiEngine == .remoteEndpoint
            ? try Self.resolve(aiEndpoint, in: settings.aiEndpoints, purpose: "AI analysis") : nil
        var cli = LocalCLIConfig.default
        if aiEngine == .localCLI {
            guard Self.digest(settings.localCLIConfig) == localCLIConfigurationDigest else {
                throw ConfigurationError.cliChanged
            }
            cli = settings.localCLIConfig
        }
        let guidance: InsightsGuidance
        if aiEngine == .remoteEndpoint {
            // Remote analysis has separate prompts and does not use the unified
            // outputLanguage parameter. Apply this attempt's selection to every
            // requested field, retaining the saved user guidance verbatim.
            let instruction: String = switch outputLanguage {
            case .english: "OUTPUT LANGUAGE: ENGLISH (Must translate if transcript is different)."
            case .dutch: "OUTPUT LANGUAGE: DUTCH (Must translate if transcript is different)."
            case .custom(let code): "OUTPUT LANGUAGE: ISO Code \(code.uppercased())."
            case .matchInput: "OUTPUT LANGUAGE: Match the language of the transcript exactly."
            }
            guidance = .init(summary: summaryPrompt + "\n\n" + instruction,
                actionItems: actionItemsPrompt + "\n\n" + instruction,
                tags: tagsPrompt + "\n\n" + instruction)
        } else {
            guidance = .init(summary: summaryPrompt, actionItems: actionItemsPrompt, tags: tagsPrompt)
        }
        return .init(engine: aiEngine, endpoint: endpoint, outputLanguage: outputLanguage,
            vocabulary: vocabulary.joined(separator: ", "),
            guidance: guidance,
            localCLIConfig: cli)
    }

    private static func metadata(_ endpoint: Endpoint?) -> Endpoint? {
        guard var endpoint else { return nil }
        endpoint.apiKey = ""
        return endpoint
    }

    private static func resolve(_ saved: Endpoint?, in current: [Endpoint], purpose: String) throws -> Endpoint {
        guard let saved, let endpoint = current.first(where: { $0.id == saved.id }) else {
            throw ConfigurationError.endpointMissing(purpose)
        }
        guard metadata(endpoint) == metadata(saved) else {
            throw ConfigurationError.endpointChanged(saved.name)
        }
        return endpoint
    }

    private static func digest(_ config: LocalCLIConfig) -> String {
        // Length-prefixing makes the command/timeout boundary unambiguous.
        let data = Data("\(config.command.utf8.count):\(config.command):\(config.timeoutSeconds)".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
