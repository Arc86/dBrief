import Foundation
import Testing
import dBriefWire
@testable import dBrief

struct SpokenSummaryLanguageTests {
    @Test func kokoroSpeaksFourLanguagesAndQwenSpeaksAll() {
        #expect(TTSEngine.kokoro.supportedLanguages == [.english, .spanish, .french, .japanese])
        #expect(TTSEngine.qwen3.supportedLanguages == TTSLanguage.allCases)
    }

    @Test func unsupportedLanguageFallsBackToEnglishPerEngine() {
        #expect(TTSEngine.kokoro.resolvedLanguage(.french) == .french)
        #expect(TTSEngine.kokoro.resolvedLanguage(.german) == .english)
        #expect(TTSEngine.qwen3.resolvedLanguage(.german) == .german)
    }

    @Test func everyKokoroLanguageHasItsOwnVoicesAndADefault() {
        let defaults: [TTSLanguage: KokoroVoice] = [.english: .afHeart, .spanish: .efDora, .french: .ffSiwis, .japanese: .jfAlpha]
        for language in TTSEngine.kokoro.supportedLanguages {
            let voices = KokoroVoice.voices(for: language)
            #expect(!voices.isEmpty)
            #expect(voices.allSatisfy { $0.language == language })
            #expect(KokoroVoice.defaultVoice(for: language) == defaults[language])
        }
        #expect(KokoroVoice.voices(for: .german).isEmpty)
        #expect(KokoroVoice.defaultVoice(for: .german) == nil)
        #expect(Set(TTSEngine.kokoro.supportedLanguages.flatMap(KokoroVoice.voices(for:))) == Set(KokoroVoice.allCases))
    }

    @Test func aVoiceFromAnotherLanguageIsReplacedByThatLanguagesDefault() {
        #expect(KokoroVoice.resolved(.bmGeorge, for: .english) == .bmGeorge)
        #expect(KokoroVoice.resolved(.emAlex, for: .spanish) == .emAlex)
        #expect(KokoroVoice.resolved(.bmGeorge, for: .spanish) == .efDora)
        #expect(KokoroVoice.resolved(.efDora, for: .japanese) == .jfAlpha)
        #expect(KokoroVoice.resolved(.jmKumo, for: .german) == .afHeart)
    }

    @Test @MainActor func rewritePromptNamesTheChosenLanguageAfterTheUsersPrompt() {
        let prompt = SpokenSummaryPrompt.systemPrompt(base: "My custom prompt.", language: .spanish)
        #expect(prompt.hasPrefix("My custom prompt."))
        #expect(prompt.hasSuffix("Write the spoken briefing in Spanish, regardless of the language of the input."))
        #expect(!AppSettings.defaultSpokenSummaryPrompt.localizedCaseInsensitiveContains("English"))
    }

    @Test @MainActor func onlyTheUnchangedOldDefaultPromptIsMigrated() {
        #expect(AppSettings.migratedSpokenSummaryPrompt(stored: nil) == AppSettings.defaultSpokenSummaryPrompt)
        #expect(AppSettings.migratedSpokenSummaryPrompt(stored: AppSettings.legacyDefaultSpokenSummaryPrompt)
                == AppSettings.defaultSpokenSummaryPrompt)
        #expect(AppSettings.migratedSpokenSummaryPrompt(stored: "Custom") == "Custom")
        #expect(AppSettings.legacyDefaultSpokenSummaryPrompt.contains("Always write the briefing in English"))
    }

    @Test func spokenPreviewUsesTheSameLanguageInstructionAsGeneration() async throws {
        let completion = CapturingCompletion()
        let service = PromptPreviewService(backends: .init(), completion: completion)
        var request = PromptPreviewRequest(identity: .init(kind: .spokenSummary, scope: .appDefaults), draftText: "Draft",
            sample: .example, configuration: .appleIntelligence, outputLanguage: .matchInput, vocabulary: "",
            summaryGuidance: "", actionItemsGuidance: "", tagsGuidance: "")
        request.spokenSummaryLanguage = .japanese
        _ = try await service.run(request)
        #expect(await completion.systemPrompt == SpokenSummaryPrompt.systemPrompt(base: "Draft", language: .japanese))
    }
}

private actor CapturingCompletion: PromptTextCompleting {
    var systemPrompt: String?
    func complete(systemPrompt: String, userMessage: String, configuration: PromptExecutionConfiguration,
                  stage: PrivacyOperation.Stage) async throws -> String {
        self.systemPrompt = systemPrompt
        return "Spoken preview"
    }
}
