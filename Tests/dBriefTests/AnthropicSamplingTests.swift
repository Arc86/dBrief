import Foundation
import Testing
@testable import dBrief

@Suite("Anthropic sampling parameters")
struct AnthropicSamplingTests {

    @Test("Current models reject non-default temperature, so it is omitted")
    func currentModelsOmitTemperature() {
        for model in ["claude-sonnet-5-5", "claude-sonnet-5", "claude-opus-5-5", "claude-opus-5",
                      "claude-opus-4-8", "claude-opus-4-7", "claude-fable-5-1", "claude-fable-5",
                      "claude-some-future-model"] {
            #expect(!AIService.anthropicAcceptsTemperature(model: model), "\(model)")
        }
    }

    @Test("Older models keep the low-temperature setting")
    func legacyModelsKeepTemperature() {
        for model in ["claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5-20251001",
                      "claude-haiku-4-5", "claude-sonnet-4-5", "claude-opus-4-5", "claude-3-5-sonnet-latest",
                      "claude-opus-4-20250514", "claude-sonnet-4-20250514"] {
            #expect(AIService.anthropicAcceptsTemperature(model: model), "\(model)")
        }
    }

    @Test("Model matching ignores case")
    func caseInsensitive() {
        #expect(AIService.anthropicAcceptsTemperature(model: "Claude-Sonnet-4-6"))
        #expect(!AIService.anthropicAcceptsTemperature(model: "Claude-Sonnet-5-5"))
    }

    @Test("Request bodies include temperature only when accepted")
    func bodyFollowsModel() {
        var current: [String: Any] = ["model": "claude-sonnet-5-5"]
        AIService.applyAnthropicSampling(to: &current, model: "claude-sonnet-5-5")
        #expect(current["temperature"] == nil)

        var legacy: [String: Any] = ["model": "claude-sonnet-4-6"]
        AIService.applyAnthropicSampling(to: &legacy, model: "claude-sonnet-4-6")
        #expect(legacy["temperature"] as? Double == 0.3)
    }
}
