import Testing
@testable import dBrief
import dBriefWire

struct WhisperModelInfoTests {
    @Test("Parse basic model: openai_whisper-small")
    func testParseBasicModel() {
        let info = WhisperModelInfo.parse("openai_whisper-small")
        #expect(info.displayName == "Whisper Small")
        #expect(info.family == "small")
        #expect(info.isEnglishOnly == false)
        #expect(info.isTurbo == false)
        #expect(info.quantizedSizeMB == nil)
        #expect(info.estimatedMemoryMB == 2048)
    }

    @Test("Parse English-only model: openai_whisper-small.en")
    func testParseEnglishOnlyModel() {
        let info = WhisperModelInfo.parse("openai_whisper-small.en")
        #expect(info.displayName == "Whisper Small (English)")
        #expect(info.family == "small")
        #expect(info.isEnglishOnly == true)
        #expect(info.isTurbo == false)
        #expect(info.quantizedSizeMB == nil)
    }

    @Test("Parse turbo model: openai_whisper-large-v3_turbo_954MB")
    func testParseTurboModel() {
        let info = WhisperModelInfo.parse("openai_whisper-large-v3_turbo_954MB")
        #expect(info.displayName == "Whisper Large V3 Turbo (954 MB)")
        #expect(info.family == "large-v3")
        #expect(info.isEnglishOnly == false)
        #expect(info.isTurbo == true)
        #expect(info.quantizedSizeMB == 954)
    }

    @Test("Parse distil model: distil-whisper_distil-large-v3_turbo_600MB")
    func testParseDistilModel() {
        let info = WhisperModelInfo.parse("distil-whisper_distil-large-v3_turbo_600MB")
        #expect(info.displayName == "Distil Large V3 Turbo (600 MB)")
        #expect(info.family == "distil-large-v3")
        #expect(info.isEnglishOnly == false)
        #expect(info.isTurbo == true)
        #expect(info.quantizedSizeMB == 600)
    }

    @Test("Parse large-v3-sep24 model: openai_whisper-large-v3-v20240930_626MB")
    func testParseV3Sep24Model() {
        let info = WhisperModelInfo.parse("openai_whisper-large-v3-v20240930_626MB")
        #expect(info.displayName == "Whisper Large V3 Sep24 (626 MB)")
        #expect(info.family == "large-v3-v20240930")
        #expect(info.isTurbo == false)
        #expect(info.quantizedSizeMB == 626)
    }

    @Test("Parse base model: openai_whisper-base")
    func testParseBaseModel() {
        let info = WhisperModelInfo.parse("openai_whisper-base")
        #expect(info.displayName == "Whisper Base")
        #expect(info.family == "base")
        #expect(info.estimatedMemoryMB == 800)
    }

    @Test("Parse tiny model: openai_whisper-tiny")
    func testParseTinyModel() {
        let info = WhisperModelInfo.parse("openai_whisper-tiny")
        #expect(info.displayName == "Whisper Tiny")
        #expect(info.family == "tiny")
        #expect(info.estimatedMemoryMB == 500)
    }

    @Test("Parse medium model: openai_whisper-medium")
    func testParseMediumModel() {
        let info = WhisperModelInfo.parse("openai_whisper-medium")
        #expect(info.displayName == "Whisper Medium")
        #expect(info.family == "medium")
        #expect(info.estimatedMemoryMB == 3072)
    }

    @Test("Memory estimation with quantized model")
    func testMemoryEstimationQuantized() {
        let info = WhisperModelInfo.parse("openai_whisper-large-v3_turbo_954MB")
        // quantized: 954 + 1024 buffer = 1978
        #expect(info.estimatedMemoryMB == 1978)
    }

    @Test("Comparable ordering: tiny < base < small")
    func testComparableOrdering() {
        let tiny = WhisperModelInfo.parse("openai_whisper-tiny")
        let base = WhisperModelInfo.parse("openai_whisper-base")
        let small = WhisperModelInfo.parse("openai_whisper-small")

        #expect(tiny < base)
        #expect(base < small)
        #expect(tiny < small)
    }

    @Test("Comparable ordering: non-english before english")
    func testComparableOrderingEnglish() {
        let standard = WhisperModelInfo.parse("openai_whisper-small")
        let english = WhisperModelInfo.parse("openai_whisper-small.en")

        #expect(standard < english)
    }

    @Test("Comparable ordering: non-turbo before turbo")
    func testComparableOrderingTurbo() {
        let standard = WhisperModelInfo.parse("openai_whisper-large-v3_626MB")
        let turbo = WhisperModelInfo.parse("openai_whisper-large-v3_turbo_626MB")

        #expect(standard < turbo)
    }

    @Test("Fallback models list has expected count")
    func testFallbackList() {
        #expect(WhisperModelInfo.fallbackModels.count == 16)
        #expect(WhisperModelInfo.fallbackModels.first?.family == "tiny")
    }
}
