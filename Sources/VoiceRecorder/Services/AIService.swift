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

    func testConnection(endpoint: Endpoint) async throws -> Bool {
        guard let baseURL = URL(string: endpoint.baseURL.trimmingSuffix("/") + "/v1/models") else {
            throw AIServiceError.invalidEndpoint
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        if !endpoint.apiKey.isEmpty {
            request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        return (200...299).contains(httpResponse.statusCode)
    }

    // MARK: - Private

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
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Invalid AI endpoint URL."
        case .invalidResponse: "Invalid response from AI server."
        case .serverError(let code, let body): "Server error (\(code)): \(body)"
        }
    }
}
