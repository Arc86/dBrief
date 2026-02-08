import Foundation

struct Endpoint: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var baseURL: String
    var modelName: String
    var apiKey: String

    init(id: UUID = UUID(), name: String, baseURL: String, modelName: String, apiKey: String = "") {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.modelName = modelName
        self.apiKey = apiKey
    }

    /// Whether this endpoint uses the whisper-asr-webservice API format (/asr)
    var isWhisperASR: Bool {
        baseURL.contains("/asr") || baseURL.hasSuffix(":8080") || baseURL.hasSuffix(":9000")
    }

    var transcriptionURL: URL? {
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

    var chatCompletionsURL: URL? {
        URL(string: baseURL.trimmingSuffix("/") + "/v1/chat/completions")
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
