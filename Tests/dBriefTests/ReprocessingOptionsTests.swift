import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor
struct ReprocessingOptionsTests {
    @Test func explicitEnglishReachesEveryTranscriptionBackendWithoutChangingDefaults() throws {
        let settings = AppSettings()
        let oldLanguage = settings.transcriptionLanguage
        let oldProfiles = settings.profiles
        let oldEndpoints = settings.transcriptionEndpoints
        defer {
            settings.transcriptionLanguage = oldLanguage
            settings.profiles = oldProfiles
            settings.transcriptionEndpoints = oldEndpoints
        }
        settings.transcriptionLanguage = "nl"
        var profile = settings.activeProfile
        profile.overrides.transcriptionLanguage = "nl"
        settings.profiles = [profile]
        let endpoint = Endpoint(name: "test", baseURL: "https://example.test", modelName: "whisper")
        settings.transcriptionEndpoints = [endpoint]
        var options = ReprocessingOptions(settings: settings, operation: .transcribe)
        options.transcriptionEndpoint = endpoint
        options.spokenLanguage = "en"
        options.parakeetModelVariant = "v3"
        options.vocabulary = []
        options.diarizationEnabled = false
        for engine in AppSettings.TranscriptionEngine.allCases {
            options.engine = engine
            let request = try options.transcriptionSettings(settings: settings)
            #expect(request.language == "en")
            #expect(request.whisper.language == "en")
            #expect(request.parakeetLanguage == "en")
            #expect(settings.transcriptionLanguage == "nl")
            #expect(settings.effectiveTranscriptionLanguage == "nl")
        }
    }

    @Test func encodedSnapshotOmitsEndpointAndCommandSecrets() throws {
        let settings = AppSettings()
        let oldCLI = settings.localCLIConfig
        defer { settings.localCLIConfig = oldCLI }
        settings.localCLIConfig = .init(command: "tool --token secret-command-token", timeoutSeconds: 42)
        var options = ReprocessingOptions(settings: settings, operation: .analysis)
        options.aiEndpoint = Endpoint(name: "test", baseURL: "https://example.test", modelName: "model", apiKey: "secret-endpoint-token")
        let data = try JSONEncoder().encode(options)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("secret-command-token"))
        #expect(!json.contains("secret-endpoint-token"))
        let restored = try JSONDecoder().decode(ReprocessingOptions.self, from: data)
        #expect(restored.aiEndpoint?.apiKey == "")
        #expect(restored.operation == .analysis)
    }

    @Test func frozenAnalysisAndCleanupIgnoreLaterGlobalChanges() throws {
        let settings = AppSettings()
        let originalOutput = settings.outputLanguage
        let originalCleanup = settings.removeFillerWords
        defer {
            settings.outputLanguage = originalOutput
            settings.removeFillerWords = originalCleanup
        }
        var options = ReprocessingOptions(settings: settings, operation: .transcribe)
        options.aiEngine = .qwenLocal
        options.engine = .appleSpeech
        options.vocabulary = []
        let savedLanguage = options.outputLanguage
        let savedCleanup = options.removeFillerWords
        let savedPrompt = options.summaryPrompt
        settings.outputLanguage = savedLanguage == .english ? .dutch : .english
        settings.removeFillerWords = !savedCleanup
        let restored = try JSONDecoder().decode(ReprocessingOptions.self, from: JSONEncoder().encode(options))
        let analysis = try restored.analysisConfiguration(settings: settings)
        #expect(analysis.outputLanguage == savedLanguage)
        #expect(analysis.guidance.summary == savedPrompt)
        #expect(try restored.transcriptionSettings(settings: settings).cleanup.removeFillerWords == savedCleanup)
    }

    @Test func endpointReplacementCannotRedirectResumedTranscription() throws {
        let settings = AppSettings()
        let endpoints = settings.transcriptionEndpoints
        defer { settings.transcriptionEndpoints = endpoints }
        let endpoint = Endpoint(name: "Frozen destination", baseURL: "https://example.test", modelName: "model")
        settings.transcriptionEndpoints = [endpoint]
        var options = ReprocessingOptions(settings: settings, operation: .transcribe)
        options.engine = .remoteEndpoint
        options.transcriptionEndpoint = endpoint
        options.vocabulary = []
        #expect(try options.transcriptionSettings(settings: settings).endpoint?.baseURL == endpoint.baseURL)
        var changed = endpoint
        changed.baseURL = "https://different.test"
        settings.transcriptionEndpoints = [changed]
        #expect(throws: ReprocessingOptions.ConfigurationError.self) {
            try options.transcriptionSettings(settings: settings)
        }
    }

    @Test func changedCLIConfigurationIsBlocked() throws {
        let settings = AppSettings()
        let original = settings.localCLIConfig
        defer { settings.localCLIConfig = original }
        var options = ReprocessingOptions(settings: settings, operation: .analysis)
        options.aiEngine = .localCLI
        #expect(try options.analysisConfiguration(settings: settings).localCLIConfig == original)
        settings.localCLIConfig = .init(command: original.command + " changed", timeoutSeconds: original.timeoutSeconds)
        #expect(throws: ReprocessingOptions.ConfigurationError.self) {
            try options.analysisConfiguration(settings: settings)
        }
    }

    @Test func savedAIEndpointIsResolvedByIdentityEvenAfterDefaultChanges() throws {
        let settings = AppSettings()
        let originals = settings.aiEndpoints
        defer { settings.aiEndpoints = originals }
        let saved = Endpoint(name: "saved", baseURL: "https://saved.test", modelName: "saved-model")
        let other = Endpoint(name: "other", baseURL: "https://other.test", modelName: "other-model")
        var options = ReprocessingOptions(settings: settings, operation: .analysis)
        options.aiEngine = .remoteEndpoint
        options.aiEndpoint = saved
        settings.aiEndpoints = [other, saved]
        #expect(try options.analysisConfiguration(settings: settings).endpoint?.id == saved.id)
        var changed = saved
        changed.modelName = "different-model"
        settings.aiEndpoints = [other, changed]
        #expect(throws: ReprocessingOptions.ConfigurationError.self) {
            try options.analysisConfiguration(settings: settings)
        }
        settings.aiEndpoints = [other]
        #expect(throws: ReprocessingOptions.ConfigurationError.self) {
            try options.analysisConfiguration(settings: settings)
        }
    }

    @Test func operationRoutingNeverTranscribesAIOrSpeakerRetries() {
        let settings = AppSettings()
        let analysis = ReprocessingOptions(settings: settings, operation: .analysis)
        #expect(!analysis.requiresTranscription)
        #expect(!analysis.requiresSpeakers)
        #expect(analysis.requiresAnalysis)
        let speakers = ReprocessingOptions(settings: settings, operation: .speakers)
        #expect(!speakers.requiresTranscription)
        #expect(speakers.requiresSpeakers)
        #expect(!speakers.requiresAnalysis)
        var transcription = ReprocessingOptions(settings: settings, operation: .transcribe)
        #expect(transcription.regenerateAI)
        transcription.regenerateAI = false
        #expect(transcription.retainedAnalysisIsStale)
        #expect(!transcription.requiresAnalysis)
    }

    @Test func unsupportedModelLanguageCombinationIsRejected() {
        let settings = AppSettings()
        var options = ReprocessingOptions(settings: settings, operation: .transcribe)
        options.engine = .parakeetLocal
        options.parakeetModelVariant = "v2"
        options.spokenLanguage = "nl"
        #expect(throws: ReprocessingOptions.ConfigurationError.self) { try options.validate() }
        options.engine = .localWhisper
        options.whisperModelName = "openai_whisper-small.en"
        #expect(throws: ReprocessingOptions.ConfigurationError.self) { try options.validate() }
    }

    @Test func remoteAnalysisPromptsApplySelectedOutputLanguageAndPreserveGuidance() throws {
        let settings = AppSettings()
        let originalEndpoints = settings.aiEndpoints
        defer { settings.aiEndpoints = originalEndpoints }
        let endpoint = Endpoint(name: "analysis", baseURL: "https://example.test", modelName: "model")
        settings.aiEndpoints = [endpoint]
        var options = ReprocessingOptions(settings: settings, operation: .analysis)
        options.aiEngine = .remoteEndpoint
        options.aiEndpoint = endpoint
        options.summaryPrompt = "Cover all decisions."
        options.actionItemsPrompt = "Include owners."
        options.tagsPrompt = "Use concise topics."
        let cases: [(OutputLanguage, String)] = [
            (.english, "ENGLISH"), (.dutch, "DUTCH"),
            (.custom("fr"), "ISO Code FR"), (.matchInput, "Match the language of the transcript")
        ]
        for (language, expected) in cases {
            options.outputLanguage = language
            let config = try options.analysisConfiguration(settings: settings)
            for prompt in [config.guidance.summary, config.guidance.actionItems, config.guidance.tags] {
                #expect(prompt?.contains(expected) == true)
            }
            #expect(config.guidance.summary?.hasPrefix(options.summaryPrompt) == true)
            #expect(config.guidance.actionItems?.hasPrefix(options.actionItemsPrompt) == true)
            #expect(config.guidance.tags?.hasPrefix(options.tagsPrompt) == true)
        }
        options.aiEngine = .qwenLocal
        let local = try options.analysisConfiguration(settings: settings)
        #expect(local.guidance.summary == options.summaryPrompt)
        #expect(local.guidance.actionItems == options.actionItemsPrompt)
        #expect(local.guidance.tags == options.tagsPrompt)
    }
}
