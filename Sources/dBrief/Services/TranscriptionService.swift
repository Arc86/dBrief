import Foundation

actor TranscriptionService {
    func transcribe(fileURL: URL, endpoint: Endpoint, language: String = "", initialPrompt: String = "") async throws -> TranscriptionResult {
        guard let url = endpoint.transcriptionURL else {
            throw TranscriptionError.invalidEndpoint
        }

        let audioData = try Data(contentsOf: fileURL)
        let fileExtension = fileURL.pathExtension.lowercased()
        let contentType: String
        switch fileExtension {
        case "wav":
            contentType = "audio/wav"
        case "ogg", "opus":
            contentType = "audio/ogg"
        default:
            contentType = "audio/m4a"
        }

        var form = MultipartFormData()
        form.addFile(
            name: endpoint.isWhisperASR ? "audio_file" : "file",
            fileName: fileURL.lastPathComponent,
            contentType: contentType,
            data: audioData
        )

        var requestURL = url
        if endpoint.isWhisperASR {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var queryItems = [
                URLQueryItem(name: "output", value: "json"),
                URLQueryItem(name: "task", value: "transcribe"),
                URLQueryItem(name: "encode", value: "true"),
            ]
            if !language.isEmpty {
                queryItems.append(URLQueryItem(name: "language", value: language))
            }
            if !initialPrompt.isEmpty {
                queryItems.append(URLQueryItem(name: "initial_prompt", value: initialPrompt))
            }
            components.queryItems = queryItems
            requestURL = components.url!
        } else {
            form.addField(name: "model", value: endpoint.modelName)
            form.addField(name: "response_format", value: "verbose_json")
            if !language.isEmpty {
                form.addField(name: "language", value: language)
            }
            if !initialPrompt.isEmpty {
                form.addField(name: "prompt", value: initialPrompt)
            }
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        if !endpoint.apiKey.isEmpty {
            request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = form.encode()
        request.timeoutInterval = 300  // 5 min for large files

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.serverError(httpResponse.statusCode, body)
        }

        return try parseResponse(data)
    }

    func testConnection(endpoint: Endpoint) async throws -> Bool {
        if endpoint.isWhisperASR {
            _ = try await fetchWhisperASRHealth(endpoint: endpoint)
            return true
        }

        _ = try await fetchAvailableModels(endpoint: endpoint)
        return true
    }

    func fetchAvailableModels(endpoint: Endpoint) async throws -> [String] {
        if endpoint.isWhisperASR {
            // whisper-asr-webservice does not expose a model listing endpoint.
            _ = try await fetchWhisperASRHealth(endpoint: endpoint)
            return []
        }

        do {
            let models = try await fetchOpenAICompatibleModels(endpoint: endpoint)
            if !models.isEmpty {
                return models
            }
        } catch {
            // Fall back to Ollama-compatible discovery.
        }

        let ollamaModels = try await fetchOllamaModels(endpoint: endpoint)
        if !ollamaModels.isEmpty {
            return ollamaModels
        }

        throw TranscriptionError.noModelsFound
    }

    private func fetchWhisperASRHealth(endpoint: Endpoint) async throws -> Data {
        let base = endpoint.baseURL.trimmingSuffix("/")
        let root = base.hasSuffix("/asr") ? String(base.dropLast(4)) : base
        guard let url = URL(string: root + "/docs") else {
            throw TranscriptionError.invalidEndpoint
        }
        return try await get(url: url, endpoint: endpoint)
    }

    private func fetchOpenAICompatibleModels(endpoint: Endpoint) async throws -> [String] {
        guard let url = URL(string: endpoint.baseURL.trimmingSuffix("/") + "/v1/models") else {
            throw TranscriptionError.invalidEndpoint
        }
        let data = try await get(url: url, endpoint: endpoint)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataItems = json["data"] as? [[String: Any]]
        else {
            throw TranscriptionError.invalidResponse
        }

        let models = dataItems
            .compactMap { $0["id"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return Array(Set(models)).sorted()
    }

    private func fetchOllamaModels(endpoint: Endpoint) async throws -> [String] {
        guard let url = URL(string: endpoint.baseURL.trimmingSuffix("/") + "/api/tags") else {
            throw TranscriptionError.invalidEndpoint
        }
        let data = try await get(url: url, endpoint: endpoint)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else {
            throw TranscriptionError.invalidResponse
        }

        let modelNames = models
            .compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return Array(Set(modelNames)).sorted()
    }

    private func get(url: URL, endpoint: Endpoint) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !endpoint.apiKey.isEmpty {
            request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.serverError(httpResponse.statusCode, responseBody)
        }
        return data
    }

    private func parseResponse(_ data: Data) throws -> TranscriptionResult {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let text = json["text"] as? String ?? ""
        let language = json["language"] as? String

        var segments: [TranscriptionResult.Segment] = []
        if let rawSegments = json["segments"] as? [[String: Any]] {
            for seg in rawSegments {
                let start = seg["start"] as? Double ?? 0
                let end = seg["end"] as? Double ?? 0
                let segText = seg["text"] as? String ?? ""
                segments.append(.init(start: start, end: end, text: segText))
            }
        }

        return TranscriptionResult(text: text, segments: segments, language: language)
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        if hasSuffix(suffix) { return String(dropLast(suffix.count)) }
        return self
    }
}

enum TranscriptionError: Error, LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case noModelsFound
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Invalid transcription endpoint URL."
        case .invalidResponse: "Invalid response from transcription server."
        case .noModelsFound: "Connected, but no models were returned by the provider."
        case .serverError(let code, let body): "Server error (\(code)): \(body)"
        }
    }
}
