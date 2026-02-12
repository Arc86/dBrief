import Foundation

actor AIService {
    func generateSummary(transcription: String, endpoint: Endpoint, systemPrompt: String) async throws -> String {
        let response = try await chatCompletion(
            systemPrompt: systemPrompt,
            userMessage: "Summarize this transcription:\n\n\(transcription)",
            endpoint: endpoint
        )
        return response
    }

    func extractActionItems(transcription: String, endpoint: Endpoint, systemPrompt: String) async throws -> [String] {
        let response = try await chatCompletion(
            systemPrompt: systemPrompt,
            userMessage: "Extract action items from this transcription:\n\n\(transcription)",
            endpoint: endpoint
        )
        return response
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .map { String($0.dropFirst(2)) }
    }

    struct TagsResult: Sendable {
        let tags: [String]
        let sentiment: String
    }

    func analyzeTags(transcription: String, endpoint: Endpoint, systemPrompt: String) async throws -> TagsResult {
        let response = try await chatCompletion(
            systemPrompt: systemPrompt,
            userMessage: "Analyze this transcription:\n\n\(transcription)",
            endpoint: endpoint
        )

        // Parse JSON response
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return TagsResult(tags: [], sentiment: "neutral")
        }

        let tags = (json["tags"] as? [String]) ?? []
        let sentiment = (json["sentiment"] as? String) ?? "neutral"
        return TagsResult(tags: tags, sentiment: sentiment)
    }

    func generateTitle(transcription: String, language: String?, endpoint: Endpoint) async throws -> String {
        let langHint = language.map { " The content is in language code '\($0)'." } ?? ""
        let response = try await chatCompletion(
            systemPrompt: "Generate a short, descriptive title (3-8 words) for the following transcription. Respond with ONLY the title, no quotes, no punctuation at the end, no explanation. The title should be in the same language as the content.\(langHint)",
            userMessage: transcription,
            endpoint: endpoint
        )
        return response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
    }

    func testConnection(endpoint: Endpoint) async throws -> Bool {
        _ = try await fetchAvailableModels(endpoint: endpoint)
        return true
    }

    func fetchAvailableModels(endpoint: Endpoint) async throws -> [String] {
        do {
            let models = try await fetchOpenAICompatibleModels(endpoint: endpoint)
            if !models.isEmpty {
                return models
            }
        } catch {
            // Fall back to Ollama-compatible discovery.
        }

        do {
            let models = try await fetchOllamaModels(endpoint: endpoint)
            if !models.isEmpty {
                return models
            }
        } catch {
            throw error
        }

        throw AIServiceError.noModelsFound
    }

    // MARK: - Private

    private func fetchOpenAICompatibleModels(endpoint: Endpoint) async throws -> [String] {
        guard let url = URL(string: endpoint.baseURL.trimmingSuffix("/") + "/v1/models") else {
            throw AIServiceError.invalidEndpoint
        }
        let data = try await get(url: url, endpoint: endpoint)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataItems = json["data"] as? [[String: Any]]
        else {
            throw AIServiceError.invalidResponse
        }

        let models = dataItems
            .compactMap { $0["id"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return Array(Set(models)).sorted()
    }

    private func fetchOllamaModels(endpoint: Endpoint) async throws -> [String] {
        guard let url = URL(string: endpoint.baseURL.trimmingSuffix("/") + "/api/tags") else {
            throw AIServiceError.invalidEndpoint
        }
        let data = try await get(url: url, endpoint: endpoint)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else {
            throw AIServiceError.invalidResponse
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
            throw AIServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIServiceError.serverError(httpResponse.statusCode, responseBody)
        }
        return data
    }

    private func chatCompletion(
        systemPrompt: String,
        userMessage: String,
        endpoint: Endpoint
    ) async throws -> String {
        guard let url = endpoint.chatCompletionsURL else {
            throw AIServiceError.invalidEndpoint
        }

        let body: [String: Any] = [
            "model": endpoint.modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage],
            ],
            "temperature": 0.3,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !endpoint.apiKey.isEmpty {
            request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIServiceError.serverError(httpResponse.statusCode, responseBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw AIServiceError.invalidResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        if hasSuffix(suffix) { return String(dropLast(suffix.count)) }
        return self
    }
}

enum AIServiceError: Error, LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case noModelsFound
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Invalid AI endpoint URL."
        case .invalidResponse: "Invalid response from AI server."
        case .noModelsFound: "Connected, but no models were returned by the provider."
        case .serverError(let code, let body): "Server error (\(code)): \(body)"
        }
    }
}
