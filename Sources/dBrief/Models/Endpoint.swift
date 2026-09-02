import Foundation

struct Endpoint: Identifiable, Codable, Hashable, Sendable {
    /// API shape of a remote endpoint. `openAICompatible` is the default and covers
    /// OpenAI, Groq, Gemini's OpenAI-compatible endpoint, Ollama, and self-hosted
    /// whisper-asr-webservice (further distinguished by `isWhisperASR`). The others use
    /// a genuinely different request/response format and are handled by dedicated
    /// adapters in `AIService` / `TranscriptionService`.
    enum Provider: String, Codable, Sendable, CaseIterable {
        case openAICompatible
        case anthropic    // AI analysis — /v1/messages
        case deepgram     // transcription — /v1/listen
        case elevenLabs   // transcription — /v1/speech-to-text
    }

    var id: UUID
    var name: String
    var baseURL: String
    var modelName: String
    var apiKey: String
    var provider: Provider

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        modelName: String,
        apiKey: String = "",
        provider: Provider = .openAICompatible
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.modelName = modelName
        self.apiKey = apiKey
        self.provider = provider
    }

    // Custom decoding so endpoints persisted before `provider` existed still load
    // (Swift's synthesized decoder would otherwise fail on the missing key).
    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, modelName, apiKey, provider
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.baseURL = try c.decode(String.self, forKey: .baseURL)
        self.modelName = try c.decode(String.self, forKey: .modelName)
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        self.provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? .openAICompatible
    }

    /// Endpoint metadata is stored in preferences, while credentials are stored
    /// separately in the Keychain under this endpoint's stable UUID. Decoding
    /// still accepts `apiKey` so older plaintext records can be migrated.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(modelName, forKey: .modelName)
        try c.encode(provider, forKey: .provider)
    }

    /// Whether this endpoint uses the whisper-asr-webservice API format (/asr)
    var isWhisperASR: Bool {
        provider == .openAICompatible
            && (baseURL.contains("/asr") || baseURL.hasSuffix(":8080") || baseURL.hasSuffix(":9000"))
    }

    var transcriptionURL: URL? {
        switch provider {
        case .deepgram:
            return URL(string: baseURL.trimmingSuffix("/") + "/v1/listen")
        case .elevenLabs:
            return URL(string: baseURL.trimmingSuffix("/") + "/v1/speech-to-text")
        case .anthropic:
            return nil // Anthropic is an AI-analysis provider, not transcription.
        case .openAICompatible:
            if isWhisperASR {
                // whisper-asr-webservice: base URL is the server root, endpoint is /asr
                let base = baseURL.trimmingSuffix("/")
                if base.hasSuffix("/asr") {
                    return URL(string: base)
                }
                return URL(string: base + "/asr")
            }
            return URL(string: baseURL.trimmingSuffix("/") + "/v1/audio/transcriptions")
        }
    }

    var chatCompletionsURL: URL? {
        URL(string: baseURL.trimmingSuffix("/") + "/v1/chat/completions")
    }

    /// Anthropic Messages API endpoint.
    var messagesURL: URL? {
        URL(string: baseURL.trimmingSuffix("/") + "/v1/messages")
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        if hasSuffix(suffix) {
            return String(dropLast(suffix.count))
        }
        return self
    }
}
