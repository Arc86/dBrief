import Foundation
import Testing
@testable import dBrief

@Suite("ReasoningConfig")
struct ReasoningConfigTests {

    @Test("Plain models get no reasoning params")
    func plainModels() {
        #expect(ReasoningConfig.disableParams(forModel: "gpt-4o").isEmpty)
        #expect(ReasoningConfig.disableParams(forModel: "llama-3.3-70b").isEmpty)
        #expect(ReasoningConfig.disableParams(forModel: "claude-sonnet-4-6").isEmpty)
    }

    @Test("GPT-5 uses minimal reasoning effort")
    func gpt5() {
        let p = ReasoningConfig.disableParams(forModel: "gpt-5")
        #expect(p["reasoning_effort"] as? String == "minimal")
    }

    @Test("o-series uses low effort")
    func oSeries() {
        #expect(ReasoningConfig.disableParams(forModel: "o3-mini")["reasoning_effort"] as? String == "low")
        #expect(ReasoningConfig.disableParams(forModel: "o1")["reasoning_effort"] as? String == "low")
    }

    @Test("gpt-oss hides reasoning")
    func gptOss() {
        let p = ReasoningConfig.disableParams(forModel: "openai/gpt-oss-120b")
        #expect(p["reasoning_effort"] as? String == "low")
        #expect(p["reasoning_format"] as? String == "hidden")
    }

    @Test("Qwen3 disables thinking via chat_template_kwargs")
    func qwen3() {
        let p = ReasoningConfig.disableParams(forModel: "qwen3-32b")
        let kwargs = p["chat_template_kwargs"] as? [String: Any]
        #expect(kwargs?["enable_thinking"] as? Bool == false)
    }

    @Test("Gemini flash turns thinking off")
    func geminiFlash() {
        #expect(ReasoningConfig.disableParams(forModel: "gemini-2.5-flash")["reasoning_effort"] as? String == "none")
        // Non-flash Gemini (Pro) is left alone.
        #expect(ReasoningConfig.disableParams(forModel: "gemini-2.5-pro").isEmpty)
    }

    @Test("apply merges params into an existing body")
    func applyMerges() {
        var body: [String: Any] = ["model": "gpt-5", "temperature": 0.3]
        ReasoningConfig.apply(to: &body, model: "gpt-5")
        #expect(body["reasoning_effort"] as? String == "minimal")
        #expect(body["temperature"] as? Double == 0.3)
    }
}
