import Foundation
import Testing
@testable import dBrief

@Suite("Integration and export privacy evidence")
struct IntegrationPrivacyTests {
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("integration-privacy-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test(arguments: ["json", "file", "failure", "missingAudio", "changed"])
    func webhookTracksActualAttemptsAndStandaloneRecording(kind: String) async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps"))
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [PrivacyWebhookProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let service = IntegrationDispatchService(session: session, privacyStore: store,
                                                privacyPendingRoot: folder.appendingPathComponent("pending"))
        let audio = folder.appendingPathComponent("private-recording.wav")
        if kind != "missingAudio" { try Data("synthetic audio".utf8).write(to: audio) }
        var config = IntegrationSettings()
        config.webhook.enabled = true
        config.webhook.url = "https://\(kind.lowercased()).invalid/private-path?token=private-key"
        config.webhook.fields = ["file", "missingAudio"].contains(kind) ? [.audio, .transcript] : [.transcript]
        let digest = try #require(try IntegrationDeliveryBatch.configurationDigests(config)[.webhook])
        let bundle = IntegrationContentBundle(title: "Private title", createdAt: Date(), durationSeconds: 1,
            audioFileURL: audio, transcript: "Private transcript", summary: nil, actionItems: [], tags: [],
            sentiment: nil, markdown: nil, calendarEvent: nil)
        let delivery = IntegrationDeliveryBatch.Delivery(id: UUID(), destination: .webhook, configurationDigest: digest)
        let batch = IntegrationDeliveryBatch(id: UUID(), recordingID: UUID(), createdAt: Date(), bundle: bundle, deliveries: [delivery])
        if kind == "changed" { config.webhook.url = "https://changed.invalid/another-path" }
        // A standalone retry can inherit a different recording's task. The
        // dispatcher must bind the batch's recording instead of borrowing it.
        let unrelated = PrivacyTrace.Context(receiptURL: folder.appendingPathComponent("other.json"),
                                            store: store, recordingID: UUID())
        let result = await PrivacyTrace.$context.withValue(unrelated) {
            await service.send(batch: batch, delivery: delivery, config: config)
        }
        #expect(try await store.load(from: unrelated.receiptURL) == nil)
        let receiptURL = PrivacyReceiptStore.sidecarURL(for: audio)
        let receipt = try await store.load(from: receiptURL)
        if ["missingAudio", "changed"].contains(kind) {
            #expect(result.status == .failed)
            #expect(receipt?.attempts.isEmpty ?? true)
            return
        }
        let attempt = try #require(receipt?.attempts.first)
        #expect(receipt?.attempts.count == 1)
        #expect(attempt.operation.stage == .integration)
        #expect(attempt.operation.destination == .remote(url: URL(string: config.webhook.url)!, provider: .webhook))
        #expect(attempt.operation.data.contains(.recordingAudio) == (kind == "file"))
        #expect(attempt.operation.data.contains(.text))
        #expect(attempt.outcome == (kind == "failure" ? .failed : .succeeded))
        if kind == "failure" {
            _ = await service.send(batch: batch, delivery: delivery, config: config)
            let retried = try #require(try await store.load(from: receiptURL))
            #expect(retried.attempts.count == 2)
            #expect(Set(retried.attempts.map(\.runID)).count == 2)
        }
        let evidence = try String(contentsOf: receiptURL, encoding: .utf8)
        for value in ["private-path", "private-key", "Private transcript", "Private title", "private-recording", "private response"] {
            #expect(!evidence.contains(value))
        }
    }

    @Test func recoveredMarkdownDoesNotInventAnotherWrite() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = PrivacyTrace.Context(receiptURL: folder.appendingPathComponent("receipt.json"),
            store: PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps")))
        let plan = MarkdownExportPlan(destination: folder.appendingPathComponent("private-note.md"),
                                       content: "Private transcript", generatedTitle: nil)
        let output = MarkdownOutputStore()
        try await PrivacyTrace.$context.withValue(context) {
            _ = try await output.publish(plan)
            _ = try await output.publish(plan)
            _ = try await output.publish(plan, alreadyCompleted: true)
        }
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.attempts.count == 1)
        #expect(receipt.attempts[0].operation.stage == .markdownExport)
        #expect(receipt.attempts[0].outcome == .succeeded)
        #expect(try String(contentsOf: plan.destination, encoding: .utf8) == plan.content)
    }
}

private final class PrivacyWebhookProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.url?.host == "failure.invalid" ? 503 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("private response".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
