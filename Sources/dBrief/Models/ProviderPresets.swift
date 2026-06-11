import Foundation

/// A curated remote-provider preset that prefills the endpoint editor (name, base URL,
/// default model, and API shape). Adding a provider is a one-line entry here plus, for
/// non-OpenAI shapes, an adapter in the corresponding service.
struct ProviderPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let provider: Endpoint.Provider
    let baseURL: String
    let defaultModel: String
    /// Short hint shown in the editor (e.g. where to get an API key).
    let help: String

    func makeEndpoint() -> Endpoint {
        Endpoint(name: name, baseURL: baseURL, modelName: defaultModel, provider: provider)
    }
}

enum ProviderPresets {
    /// AI-analysis providers.
    static let ai: [ProviderPreset] = [
        ProviderPreset(id: "anthropic", name: "Anthropic (Claude)", provider: .anthropic,
                       baseURL: "https://api.anthropic.com", defaultModel: "claude-sonnet-4-6",
                       help: "API key from console.anthropic.com"),
        ProviderPreset(id: "gemini", name: "Google Gemini", provider: .openAICompatible,
                       baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: "gemini-2.5-flash",
                       help: "OpenAI-compatible endpoint. API key from aistudio.google.com"),
        ProviderPreset(id: "openai", name: "OpenAI", provider: .openAICompatible,
                       baseURL: "https://api.openai.com", defaultModel: "gpt-4o",
                       help: "API key from platform.openai.com"),
        ProviderPreset(id: "groq-chat", name: "Groq", provider: .openAICompatible,
                       baseURL: "https://api.groq.com/openai", defaultModel: "llama-3.3-70b-versatile",
                       help: "Fast inference. API key from console.groq.com"),
        ProviderPreset(id: "ollama", name: "Ollama (local)", provider: .openAICompatible,
                       baseURL: "http://localhost:11434", defaultModel: "llama3",
                       help: "Local models, no API key needed"),
    ]

    /// Transcription providers.
    static let transcription: [ProviderPreset] = [
        ProviderPreset(id: "groq-asr", name: "Groq Whisper", provider: .openAICompatible,
                       baseURL: "https://api.groq.com/openai", defaultModel: "whisper-large-v3-turbo",
                       help: "Fast, low-cost Whisper. API key from console.groq.com"),
        ProviderPreset(id: "deepgram", name: "Deepgram", provider: .deepgram,
                       baseURL: "https://api.deepgram.com", defaultModel: "nova-3",
                       help: "Word timestamps + diarization. API key from console.deepgram.com"),
        ProviderPreset(id: "elevenlabs", name: "ElevenLabs Scribe", provider: .elevenLabs,
                       baseURL: "https://api.elevenlabs.io", defaultModel: "scribe_v1",
                       help: "90+ languages. API key from elevenlabs.io"),
        ProviderPreset(id: "openai-asr", name: "OpenAI / Whisper API", provider: .openAICompatible,
                       baseURL: "https://api.openai.com", defaultModel: "whisper-1",
                       help: "OpenAI-compatible /v1/audio/transcriptions"),
    ]

    /// Blank custom endpoint for the "Custom…" menu option.
    static func custom(modelPlaceholder: String) -> Endpoint {
        Endpoint(name: "", baseURL: "http://localhost:11434", modelName: modelPlaceholder, provider: .openAICompatible)
    }
}
