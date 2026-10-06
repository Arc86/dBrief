import Testing
import MLXLMCommon
@testable import dBriefMLHost

@Suite struct GemmaGenerationConfigTests {
    @Test func kvCacheUsesTurboQuantWithPartialCompatibility() throws {
        let config = GemmaGenerationConfig.kvCache
        #expect(config.strategy.identifier == .turboQuant)
        // Gemma's sliding-window layers can't compress; partial must be allowed or
        // generation would be rejected outright (F6).
        #expect(config.compatibility == .allowPartial)
        #expect(config.capacity == nil) // a capacity would make every layer rotating → nothing compresses
    }

    @Test func budgetsAreOrdered() {
        #expect(GemmaGenerationConfig.chunkTokenBudget < GemmaGenerationConfig.singlePassTokenBudget)
        // The reduce prompt may exceed the (eval-tuned, small) single-pass threshold, but must stay
        // within the ~24K-token inputs Gemma was already handling comfortably.
        #expect(GemmaGenerationConfig.reduceInputTokenBudget <= 24_000)
    }
}
