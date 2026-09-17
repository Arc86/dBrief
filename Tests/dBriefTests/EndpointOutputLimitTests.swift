import Foundation
import Testing
@testable import dBrief

@Suite("Endpoint output limits")
struct EndpointOutputLimitTests {
    @Test("Preset requests use model-aware defaults", arguments: ProviderPresets.ai)
    func presets(preset: ProviderPreset) async throws {
        let endpoint = preset.makeEndpoint()
        let expected = preset.id == "ollama" ? 4096 : 16_384
        #expect(try await response(endpoint) == String(expected))
    }

    @Test("Custom limits survive storage and reach both API shapes and streaming",
          arguments: [Endpoint.Provider.openAICompatible, .anthropic], [false, true])
    func customLimits(provider: Endpoint.Provider, streaming: Bool) async throws {
        let original = Endpoint(name: "Custom", baseURL: "https://custom.invalid",
            modelName: "custom-model", provider: provider)
        let endpoint = try withLimit(32_768, endpoint: original)
        let stored = try JSONEncoder().encode(endpoint)
        let json = try JSONSerialization.jsonObject(with: stored) as! [String: Any]
        #expect(json["maxOutputTokens"] as? Int == 32_768)
        #expect(json["apiKey"] == nil)
        let restored = try JSONDecoder().decode(Endpoint.self, from: stored)
        #expect(try await response(restored, streaming: streaming) == "32768")
    }

    @Test("Legacy saved cloud entries adopt the preset default")
    func legacy() async throws {
        let json = #"{"id":"07821A80-4CE7-4611-B6DF-1ED3ED4A4A72","name":"Saved","baseURL":"https://api.openai.com","modelName":"gpt-4o"}"#
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(json.utf8))
        #expect(try await response(endpoint) == "16384")
    }

    @Test("Unknown models and lookalike hosts keep conservative defaults", arguments: [
        ("https://api.openai.com", "unknown-model"),
        ("https://api.openai.com.example.invalid", "gpt-4o"),
        ("http://localhost:8080", "gpt-4o"),
    ])
    func unknownModels(value: (String, String)) async throws {
        let endpoint = Endpoint(name: "OpenAI", baseURL: value.0, modelName: value.1)
        #expect(try await response(endpoint) == "4096")
    }

    @Test("Invalid saved limits fall back to a safe default", arguments: [0, -1])
    func invalidLimits(limit: Int) async throws {
        let endpoint = try withLimit(limit, endpoint: Endpoint(name: "Custom",
            baseURL: "https://custom.invalid", modelName: "custom"))
        #expect(try await response(endpoint) == "4096")
    }

    @Test("Explicit small limits override cloud defaults")
    func smallerOverride() async throws {
        let endpoint = try withLimit(2048, endpoint: ProviderPresets.ai[0].makeEndpoint())
        #expect(try await response(endpoint) == "2048")
    }

    @Test("Changing model updates automatic limits while preserving explicit overrides")
    func modelChanges() async throws {
        var endpoint = ProviderPresets.ai[0].makeEndpoint()
        endpoint.modelName = "unknown-model"
        #expect(try await response(endpoint) == "4096")
        endpoint.maxOutputTokens = 8192
        endpoint.modelName = "claude-sonnet-4-6"
        #expect(try await response(endpoint) == "8192")
        endpoint.maxOutputTokens = nil
        #expect(try await response(endpoint) == "16384")
    }

    private func withLimit(_ limit: Int, endpoint: Endpoint) throws -> Endpoint {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(endpoint)) as! [String: Any]
        json["maxOutputTokens"] = limit
        return try JSONDecoder().decode(Endpoint.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func response(_ endpoint: Endpoint, streaming: Bool = false) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OutputLimitProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = AIService(session: session)
        if streaming {
            var result = ""
            for try await chunk in service.streamChat(systemPrompt: "System", userMessage: "User", endpoint: endpoint) {
                result += chunk
            }
            return result
        }
        return try await service.generateSummary(transcription: "Transcript", endpoint: endpoint, systemPrompt: "System")
    }
}

private final class OutputLimitProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let tokens = body["max_tokens"] as? Int ?? 0
            if tokens >= 16_384 && request.timeoutInterval < 600 { throw URLError(.timedOut) }
            let streaming = body["stream"] as? Bool == true
            let anthropic = request.url?.path.hasSuffix("/messages") == true
            let text = String(tokens)
            let payload: String
            if streaming {
                payload = anthropic
                    ? "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}\n\n"
                    : "data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"}}]}\n\ndata: [DONE]\n\n"
            } else {
                payload = anthropic
                    ? "{\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}],\"stop_reason\":\"end_turn\"}"
                    : "{\"choices\":[{\"message\":{\"content\":\"\(text)\"},\"finish_reason\":\"stop\"}]}"
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(payload.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
