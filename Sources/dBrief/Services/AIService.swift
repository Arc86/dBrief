import Foundation
import dBriefWire

actor AIService {
    /// Upper bound on generated tokens per call. Two opposing pressures:
    /// some servers default to a tiny `max_tokens` (e.g. 16) which truncates the
    /// answer, while strict servers (vLLM) reject when `prompt + max_tokens` exceeds
    /// the model's context window. A moderate cap covers dBrief's short outputs
    /// (summary/action-items/tags) plus a reasoning model's `<think>` block without
    /// reserving so much context that it triggers overflow on small-context servers.
    static let maxResponseTokens = 4096
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
        return Self.parseActionItems(from: response)
    }

    /// Extracts action items from a raw model response, tolerating a leading
    /// `<think>` reasoning block and `-`, `*`, `•`, or `1.` list markers.
    nonisolated static func parseActionItems(from response: String) -> [String] {
        cleanContent(response)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { line -> String? in
                for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                    return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                }
                // Numbered list: "1. ", "12) ", etc.
                if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                    return String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                return nil
            }
            .filter { !$0.isEmpty }
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

        return Self.parseTags(from: response)
    }

    /// Parses the tags/sentiment JSON from a raw model response, skipping any
    /// `<think>` block and surrounding prose or Markdown code fences.
    nonisolated static func parseTags(from response: String) -> TagsResult {
        guard let jsonText = LocalInsightsDecoder.extractFirstJSONObject(response),
              let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return TagsResult(tags: [], sentiment: "neutral")
        }

        let tags = (json["tags"] as? [String]) ?? []
        let sentiment = (json["sentiment"] as? String) ?? "neutral"
        return TagsResult(tags: tags, sentiment: sentiment)
    }

    /// Detects a context-window-overflow error from a server error body, across the
    /// common phrasings (llama.cpp: "exceeds the available context size"; vLLM/OpenAI:
    /// "maximum context length"/"context_length_exceeded"; others: "context window").
    nonisolated static func isContextOverflow(_ body: String) -> Bool {
        let lowered = body.lowercased()
        let needles = [
            "context size",
            "context length",
            "context window",
            "context_length_exceeded",
            "maximum context",
            "exceeds the available context",
            "reduce the length",
        ]
        return needles.contains { lowered.contains($0) }
    }

    /// Removes complete `<think>…</think>` reasoning blocks that some models inline
    /// in their `content`, leaving the trimmed answer.
    nonisolated static func cleanContent(_ raw: String) -> String {
        var s = raw
        while let open = s.range(of: "<think>"),
              let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Streaming chat completion via SSE. Yields text delta chunks as they arrive.
    nonisolated func streamChat(
        systemPrompt: String,
        userMessage: String,
        endpoint: Endpoint
    ) -> AsyncThrowingStream<String, Error> {
        let isAnthropic = endpoint.provider == .anthropic
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request: URLRequest = try {
                        isAnthropic
                            ? try Self.anthropicStreamRequest(systemPrompt: systemPrompt, userMessage: userMessage, endpoint: endpoint)
                            : try Self.openAIStreamRequest(systemPrompt: systemPrompt, userMessage: userMessage, endpoint: endpoint)
                    }()

                    let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode)
                    else {
                        throw AIServiceError.invalidResponse
                    }

                    for try await line in asyncBytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        if jsonStr.trimmingCharacters(in: .whitespaces) == "[DONE]" { break }
                        guard let data = jsonStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if isAnthropic {
                            // Anthropic SSE: text arrives in content_block_delta events.
                            guard (json["type"] as? String) == "content_block_delta",
                                  let delta = json["delta"] as? [String: Any],
                                  let text = delta["text"] as? String
                            else { continue }
                            continuation.yield(text)
                        } else {
                            guard let choices = json["choices"] as? [[String: Any]],
                                  let delta = choices.first?["delta"] as? [String: Any],
                                  let content = delta["content"] as? String
                            else { continue }
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private nonisolated static func openAIStreamRequest(
        systemPrompt: String,
        userMessage: String,
        endpoint: Endpoint
    ) throws -> URLRequest {
        guard let url = endpoint.chatCompletionsURL else { throw AIServiceError.invalidEndpoint }
        var body: [String: Any] = [
            "model": endpoint.modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage],
            ],
            "temperature": 0.3,
            "max_tokens": Self.maxResponseTokens,
            "stream": true,
        ]
        ReasoningConfig.apply(to: &body, model: endpoint.modelName)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !endpoint.apiKey.isEmpty {
            request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120
        return request
    }

    private nonisolated static func anthropicStreamRequest(
        systemPrompt: String,
        userMessage: String,
        endpoint: Endpoint
    ) throws -> URLRequest {
        guard let url = endpoint.messagesURL else { throw AIServiceError.invalidEndpoint }
        let body: [String: Any] = [
            "model": endpoint.modelName,
            "max_tokens": 4096,
            "temperature": 0.3,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]],
            "stream": true,
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !endpoint.apiKey.isEmpty {
            request.setValue(endpoint.apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120
        return request
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
        if endpoint.provider == .anthropic {
            return try await anthropicCompletion(systemPrompt: systemPrompt, userMessage: userMessage, endpoint: endpoint)
        }
        return try await openAICompletion(systemPrompt: systemPrompt, userMessage: userMessage, endpoint: endpoint)
    }

    private func openAICompletion(
        systemPrompt: String,
        userMessage: String,
        endpoint: Endpoint
    ) async throws -> String {
        guard let url = endpoint.chatCompletionsURL else {
            throw AIServiceError.invalidEndpoint
        }

        var body: [String: Any] = [
            "model": endpoint.modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage],
            ],
            "temperature": 0.3,
            "max_tokens": Self.maxResponseTokens,
        ]
        ReasoningConfig.apply(to: &body, model: endpoint.modelName)

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
            if Self.isContextOverflow(responseBody) {
                throw AIServiceError.contextWindowExceeded
            }
            throw AIServiceError.serverError(httpResponse.statusCode, responseBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any]
        else {
            throw AIServiceError.invalidResponse
        }

        // Reasoning models may put their answer in `content` and the chain-of-thought
        // in `reasoning_content`. A null/empty `content` usually means the generation
        // was truncated mid-thinking (finish_reason == "length") — surface that
        // clearly instead of a generic "invalid response".
        let cleaned = Self.cleanContent((message["content"] as? String) ?? "")
        guard !cleaned.isEmpty else {
            let finishReason = firstChoice["finish_reason"] as? String
            let hasReasoning = (message["reasoning_content"] as? String)?.isEmpty == false
            if finishReason == "length" || hasReasoning {
                throw AIServiceError.truncatedResponse
            }
            throw AIServiceError.invalidResponse
        }

        return cleaned
    }

    // MARK: - Anthropic (native /v1/messages)

    private func anthropicCompletion(
        systemPrompt: String,
        userMessage: String,
        endpoint: Endpoint
    ) async throws -> String {
        guard let url = endpoint.messagesURL else {
            throw AIServiceError.invalidEndpoint
        }

        let body: [String: Any] = [
            "model": endpoint.modelName,
            "max_tokens": 4096,
            "temperature": 0.3,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !endpoint.apiKey.isEmpty {
            request.setValue(endpoint.apiKey, forHTTPHeaderField: "x-api-key")
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

        return Self.parseAnthropicText(data).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract the concatenated text from an Anthropic Messages response body.
    /// Pure + static so it's unit-testable.
    static func parseAnthropicText(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else { return "" }
        return content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
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
    case truncatedResponse
    case contextWindowExceeded
    case noModelsFound
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Invalid AI endpoint URL."
        case .invalidResponse: "Invalid response from AI server."
        case .truncatedResponse: "The model returned no answer — it likely ran out of output tokens while \"thinking\". Try a non-reasoning model or one with a larger output limit."
        case .contextWindowExceeded: "The transcript is larger than the model's context window. Increase your server's context size (e.g. llama.cpp --ctx-size / vLLM --max-model-len) or use an endpoint with a larger context."
        case .noModelsFound: "Connected, but no models were returned by the provider."
        case .serverError(let code, let body): "Server error (\(code)): \(body)"
        }
    }
}
