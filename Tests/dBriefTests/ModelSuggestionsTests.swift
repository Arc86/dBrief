import Testing
import dBriefWire
@testable import dBrief

struct ModelSuggestionsTests {
    /// The picker's default list: curated Whisper + every Parakeet variant + Apple.
    private let defaults = WhisperModelCatalog.curatedIDs
        + ParakeetModelInfo.variants.map { LocalTranscriptionChoice.parakeet($0.id) }
        + [LocalTranscriptionChoice.apple]
    private let turbo = WhisperModelInfo.recommendedModelID

    private func picks(_ language: String, ram: Double = 16, macOS: Int = 26, speakers: Bool = true,
                       available: [String]? = nil, downloaded: Set<String> = []) -> [ModelSuggestion] {
        ModelSuggestions.picks(language: language, installedRAMGiB: ram, macOSMajor: macOS,
                               identifySpeakers: speakers, available: available ?? defaults, downloaded: downloaded)
    }

    private func byIntent(_ s: [ModelSuggestion]) -> [ModelIntent: String] {
        Dictionary(uniqueKeysWithValues: s.map { ($0.intent, $0.modelID) })
    }

    @Test(arguments: [true, false]) func autoDetectOn16GB(speakers: Bool) {
        let result = picks("", speakers: speakers)
        #expect(result.map(\.intent) == [.fastest, .recommended, .mostAccurate])
        #expect(byIntent(result) == [.recommended: turbo, .mostAccurate: "parakeet:ultra", .fastest: "parakeet:v3"])
    }

    @Test(arguments: [true, false]) func englishOnMacOS15PrefersPhonon2(speakers: Bool) {
        let result = byIntent(picks("en-US", macOS: 15, speakers: speakers))
        #expect(result == [.recommended: turbo, .mostAccurate: "parakeet:ultra", .fastest: "parakeet:phonon2"])
    }

    @Test(arguments: [true, false]) func japaneseFallsBackToWhisper(speakers: Bool) {
        let result = byIntent(picks("ja", speakers: speakers))
        #expect(result == [.recommended: turbo, .mostAccurate: "openai_whisper-large-v3", .fastest: "openai_whisper-tiny"])
    }

    @Test(arguments: [true, false]) func autoDetectOn8GB(speakers: Bool) {
        let result = byIntent(picks("", ram: 8, speakers: speakers))
        #expect(result == [.recommended: turbo, .mostAccurate: "parakeet:ultra", .fastest: "parakeet:v3"])
    }

    @Test func macOS14HasNoReduxOrPhonon2() {
        let result = picks("en", macOS: 14)
        #expect(!result.contains { $0.modelID == "parakeet:redux" || $0.modelID == "parakeet:phonon2" })
        #expect(byIntent(result)[.fastest] == "parakeet:v2")
    }

    @Test func mostAccurateIsOmittedWhenNothingBeatsRecommended() {
        // Japanese on 8 GB: Large v3 (5.5 GB with speakers) is over the 4 GB limit.
        let result = picks("ja", ram: 8)
        #expect(result.map(\.intent) == [.fastest, .recommended])
        #expect(byIntent(result) == [.fastest: "openai_whisper-tiny", .recommended: turbo])
    }

    @Test func fewerEligibleModelsGiveFewerTiles() {
        let result = picks("", available: [turbo, "parakeet:v3"])
        #expect(byIntent(result) == [.recommended: turbo, .fastest: "parakeet:v3"])
        #expect(picks("", available: []).isEmpty)
        #expect(picks("", available: [LocalTranscriptionChoice.apple]).isEmpty)
    }

    @Test func parakeetOnlyCatalogStillSuggests() {
        let parakeet = ParakeetModelInfo.variants.map { LocalTranscriptionChoice.parakeet($0.id) }
        let result = picks("", available: parakeet)
        #expect(byIntent(result) == [.recommended: "parakeet:ultra", .fastest: "parakeet:v3"])
        #expect(result.first { $0.intent == .recommended }?.reason == "Best fit for your meetings on this Mac.")
    }

    @Test func lowMemoryMacFallsBack() {
        // 4 GB with speakers: limit 2 GB. Turbo (2.2) and Parakeet v3/Ultra (2.26) don't fit.
        let result = picks("", ram: 4)
        #expect(byIntent(result) == [.recommended: "parakeet:redux", .fastest: "openai_whisper-tiny"])
        for suggestion in result {
            let ram = LocalTranscriptionChoice.profile(suggestion.modelID)?.runtimeGiB ?? 99
            #expect(ram + ModelSuggestions.speakersGiB <= 2)
        }
    }

    @Test func reasonsExplainThePick() {
        let auto = picks("", downloaded: [turbo])
        #expect(auto.first { $0.intent == .fastest }?.reason
                == "Quickest on Apple Silicon. Skip it for meetings in other languages.")
        #expect(auto.first { $0.intent == .recommended }?.reason
                == "Best all-rounder: any language, light on memory. Ready now.")
        #expect(auto.first { $0.intent == .mostAccurate }?.reason == "Fewest errors in 25 European languages.")
        #expect(picks("").first { $0.intent == .recommended }?.reason
                == "Best all-rounder: any language, light on memory.")

        let japanese = picks("ja")
        #expect(japanese.first { $0.intent == .fastest }?.reason
                == "Quickest for Japanese on this Mac. Lowest accuracy; for quick drafts.")
        #expect(japanese.first { $0.intent == .mostAccurate }?.reason
                == "Slow. For recordings where every word matters.")
        #expect(picks("nl").first { $0.intent == .mostAccurate }?.reason == "Fewest errors for Dutch meetings.")
        #expect(picks("nl").first { $0.intent == .fastest }?.reason == "Quickest for Dutch on this Mac.")
    }

    @Test func intentPresentation() {
        #expect(ModelIntent.fastest.title == "Fastest")
        #expect(ModelIntent.recommended.title == "Recommended")
        #expect(ModelIntent.mostAccurate.title == "Most accurate")
        #expect(ModelSuggestions.languageName("") == nil)
        #expect(ModelSuggestions.languageName("nl-NL") == "Dutch")
    }
}
