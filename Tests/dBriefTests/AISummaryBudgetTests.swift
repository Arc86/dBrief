import Foundation
import Testing
@testable import dBrief

@Suite("Remote summary output budget")
struct AISummaryBudgetTests {
    @Test("OpenRouter summary has room for reasoning and a complete answer", arguments: [
        "https://openrouter.ai/api", "https://openrouter.ai/api/",
    ])
    func longSummary(baseURL: String) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let endpoint = Endpoint(name: "Router", baseURL: baseURL,
            modelName: "z-ai/glm-5.3-flash", apiKey: "")
        let summary = try await AIService(session: session).generateSummary(
            transcription: "Meeting transcript", endpoint: endpoint, systemPrompt: "Summarize")
        #expect(summary == "Complete meeting summary.")
    }

    @Test("Other endpoints retain a modest budget for small context windows", arguments: [
        "http://localhost:8080", "https://openrouter.ai.example.invalid/api",
    ])
    func otherEndpoints(baseURL: String) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let endpoint = Endpoint(name: "OpenRouter", baseURL: baseURL,
            modelName: "z-ai/glm-5.3-flash", apiKey: "")
        let summary = try await AIService(session: session).generateSummary(
            transcription: "Meeting transcript", endpoint: endpoint, systemPrompt: "Summarize")
        #expect(summary == "Complete meeting summary.")
    }

    @Test("OpenRouter action items use the endpoint allowance too")
    func actionItems() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let endpoint = Endpoint(name: "Router", baseURL: "https://openrouter.ai/api",
            modelName: "z-ai/glm-5.3-flash", apiKey: "")
        let items = try await AIService(session: session).extractActionItems(
            transcription: "Meeting transcript", endpoint: endpoint, systemPrompt: "Extract actions")
        #expect(items == ["Send the notes"])
    }

    @Test("Still rejects an incomplete summary at the larger limit", arguments: [false, true])
    func exhaustedBudget(emptyContent: Bool) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let endpoint = Endpoint(name: "Router", baseURL: "https://openrouter.ai/api",
            modelName: emptyContent ? "fixture-empty" : "fixture-truncated", apiKey: "", maxOutputTokens: 16_384)
        do {
            _ = try await AIService(session: session).generateSummary(
                transcription: "Meeting transcript", endpoint: endpoint, systemPrompt: "Summarize")
            Issue.record("An incomplete summary must not be saved as successful")
        } catch AIServiceError.truncatedResponse {
            // Expected for both partial text and reasoning-only responses.
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SummaryBudgetProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class SummaryBudgetProtocol: URLProtocol, @unchecked Sendable {
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
            let messages = body["messages"] as! [[String: String]]
            let isSummary = messages.last?["content"]?.hasPrefix("Summarize this transcription:") == true
            let isRouterSummary = request.url?.host == "openrouter.ai" && isSummary
            let budget = body["max_tokens"] as? Int ?? 0
            let model = body["model"] as? String ?? ""
            if isRouterSummary && budget >= 6000 && request.timeoutInterval < 360 {
                throw URLError(.timedOut)
            }
            // Emulate combined reasoning + answer needing 6,000 output tokens.
            // Other calls emulate a server with limited context reservation.
            let truncated = (isRouterSummary && budget < 6000) || model.hasPrefix("fixture-")
            let expectedBudget = request.url?.host == "openrouter.ai" ? 16_384 : 4096
            let status = budget != expectedBudget ? 400 : 200
            let content: Any = model == "fixture-empty" ? NSNull() :
                (truncated ? "Partial summary" : isSummary ? "Complete meeting summary." : "- Send the notes")
            let responseBody: [String: Any] = ["choices": [[
                "finish_reason": truncated ? "length" : "stop",
                "message": ["role": "assistant", "content": content],
            ]]]
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: responseBody))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
