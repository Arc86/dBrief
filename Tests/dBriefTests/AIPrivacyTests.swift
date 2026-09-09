import Foundation
import Testing
@testable import dBrief

@Suite("AI request privacy evidence")
struct AIPrivacyTests {
    @Test(arguments: ["summary", "actionItems", "tags", "title", "chat", "anthropic", "failure", "streamFailure", "spelling", "spokenSummaryScript"])
    func actualRequestStagesAndStreamingOutcomes(kind: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ai-privacy-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrivacyAIProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = AIService(session: session)
        let endpoint = Endpoint(name: "Private endpoint name", baseURL: "https://\(kind.lowercased()).invalid",
            modelName: "fixture-model", apiKey: "private-test-key", provider: kind == "anthropic" ? .anthropic : .openAICompatible)
        let context = PrivacyTrace.Context(receiptURL: folder.appendingPathComponent("receipt.json"), store: PrivacyReceiptStore())
        var caughtError = false
        do {
            try await PrivacyTrace.$context.withValue(context) {
                switch kind {
                case "summary", "anthropic", "failure":
                    _ = try await service.generateSummary(transcription: "Private transcript", endpoint: endpoint, systemPrompt: "Private prompt")
                case "actionItems":
                    _ = try await service.extractActionItems(transcription: "Private transcript", endpoint: endpoint, systemPrompt: "Private prompt")
                case "tags":
                    _ = try await service.analyzeTags(transcription: "Private transcript", endpoint: endpoint, systemPrompt: "Private prompt")
                case "title":
                    _ = try await service.generateTitle(transcription: "Private transcript", language: "en", endpoint: endpoint)
                default:
                    var text = ""
                    for try await chunk in service.streamChat(systemPrompt: "Private prompt", userMessage: "Private transcript", endpoint: endpoint,
                        stage: kind == "spelling" ? .spelling : kind == "spokenSummaryScript" ? .spokenSummaryScript : .chat) { text += chunk }
                    #expect(text == "Reply")
                }
            }
        } catch { caughtError = true }
        #expect(caughtError == (kind == "failure" || kind == "streamFailure"))
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        let attempt = try #require(receipt.attempts.first)
        #expect(receipt.attempts.count == 1)
        let expectedStage = kind == "anthropic" || kind == "failure" ? "summary" : kind == "streamFailure" ? "chat" : kind
        #expect(attempt.operation.stage.rawValue == expectedStage)
        #expect(attempt.operation.data.contains(.text))
        #expect(attempt.operation.destination.provider == (kind == "anthropic" ? .anthropic : .openAICompatible))
        #expect(attempt.operation.destination.model == "fixture-model")
        #expect(attempt.outcome == (caughtError ? .failed : .succeeded))
        let bytes = try String(contentsOf: context.receiptURL, encoding: .utf8)
        for secret in ["Private transcript", "Private prompt", "private-test-key", "Private endpoint name", "Reply", "context length"] {
            #expect(!bytes.contains(secret))
        }
    }
}

private final class PrivacyAIProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url!.host!
        let stream = ["chat.invalid", "streamfailure.invalid", "spelling.invalid", "spokensummaryscript.invalid"].contains(host)
        let status = host == "failure.invalid" ? 400 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": stream ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body: String
        if stream { body = "data: {\"choices\":[{\"delta\":{\"content\":\"Reply\"}}]}\n\n" }
        else if host == "anthropic.invalid" { body = #"{"content":[{"type":"text","text":"Reply"}]}"# }
        else if status == 400 { body = #"{"error":"context length exceeded"}"# }
        else { body = #"{"choices":[{"message":{"content":"Reply"}}]}"# }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        if host == "streamfailure.invalid" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            if stream { client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8)) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
