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
        let testURL: URL
        if endpoint.isWhisperASR {
            // whisper-asr-webservice: check /docs endpoint
            let base = endpoint.baseURL.trimmingSuffix("/")
            let root = base.hasSuffix("/asr") ? String(base.dropLast(4)) : base
            guard let url = URL(string: root + "/docs") else {
                throw TranscriptionError.invalidEndpoint
            }
            testURL = url
        } else {
            guard let url = URL(string: endpoint.baseURL.trimmingSuffix("/") + "/v1/models") else {
                throw TranscriptionError.invalidEndpoint
            }
            testURL = url
        }

        var request = URLRequest(url: testURL)
        request.httpMethod = "GET"
        if !endpoint.apiKey.isEmpty {
            request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        return (200...299).contains(httpResponse.statusCode)
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
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Invalid transcription endpoint URL."
        case .invalidResponse: "Invalid response from transcription server."
        case .serverError(let code, let body): "Server error (\(code)): \(body)"
        }
    }
}
