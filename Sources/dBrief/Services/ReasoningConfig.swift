import Foundation

/// Best-effort suppression of chain-of-thought / "thinking" output for remote
/// OpenAI-compatible models that emit it. Reasoning tokens add latency and can leak
/// into the JSON-shaped insights output, so we ask the model to skip or hide them.
///
/// Inspired by VoiceInk's `ReasoningConfig`. Keyed by model-name substring so a plain
/// model (e.g. `gpt-4o`, `llama-3.3`) gets `[:]` and its request is untouched — only
/// recognized reasoning models, whose providers accept these fields, are modified.
enum ReasoningConfig {

    /// Extra request-body keys to merge into an OpenAI-compatible chat-completions body
    /// to disable/hide reasoning for `model`, or `[:]` when the model isn't a known
    /// reasoning model.
    static func disableParams(forModel model: String) -> [String: Any] {
        let m = model.lowercased()

        // OpenAI GPT-5 family: supports a "minimal" reasoning effort.
        if m.contains("gpt-5") {
            return ["reasoning_effort": "minimal"]
        }
        // OpenAI o-series reasoning models: lowest supported effort is "low".
        if m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
            || m.contains("-o1") || m.contains("-o3") || m.contains("-o4") {
            return ["reasoning_effort": "low"]
        }
        // OpenAI gpt-oss (served by Groq, etc.): low effort + hide the reasoning channel.
        if m.contains("gpt-oss") {
            return ["reasoning_effort": "low", "reasoning_format": "hidden"]
        }
        // Qwen3 thinking models: vLLM/Ollama OpenAI-compatible convention.
        if m.contains("qwen3") || m.contains("qwen-3") {
            return ["chat_template_kwargs": ["enable_thinking": false]]
        }
        // Gemini 2.5/3 flash via Google's OpenAI-compatible endpoint: "none" turns
        // thinking off where the model allows it.
        if m.contains("gemini") && m.contains("flash") {
            return ["reasoning_effort": "none"]
        }
        return [:]
    }

    /// Merge `disableParams(forModel:)` into an existing request body in place.
    static func apply(to body: inout [String: Any], model: String) {
        for (key, value) in disableParams(forModel: model) {
            body[key] = value
        }
    }
}
