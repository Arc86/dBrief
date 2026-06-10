import Testing
@testable import dBrief
import dBriefWire

@MainActor
@Suite("AppSettings.whisperRuntimeConfig")
struct WhisperRuntimeConfigBuilderTests {
    @Test("Empty language maps to nil; other fields mirror settings")
    func mapsFields() {
        let s = AppSettings()
        s.whisperModelName = "openai_whisper-large-v3_turbo"
        s.transcriptionLanguage = ""
        s.diarizationEnabled = true
        let cfg = s.whisperRuntimeConfig
        #expect(cfg.modelName == "openai_whisper-large-v3_turbo")
        #expect(cfg.language == nil)
        #expect(cfg.diarizationEnabled == true)
    }

    @Test("Non-empty language is passed through")
    func languagePassthrough() {
        let s = AppSettings()
        s.transcriptionLanguage = "en"
        #expect(s.whisperRuntimeConfig.language == "en")
    }
}
