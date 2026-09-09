import Foundation
import Testing
@testable import dBrief

@Suite("HTTP privacy evidence")
struct PrivacyHTTPTraceTests {
    @Test("Real URLSession redirects distinguish forwarded audio from GET/query-only requests", arguments: [302, 307])
    func redirectChain(status: Int) async throws {
        let server = try ReceiptRedirectServer(status: status)
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-http-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("synthetic-audio.wav")
        let payload = Data("synthetic recording bytes".utf8)
        try payload.write(to: file)
        var request = URLRequest(url: server.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        let context = PrivacyTrace.Context(receiptURL: folder.appendingPathComponent("receipt.json"),
            store: PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps")))
        let operation = PrivacyOperation(stage: .transcription, data: [.recordingAudio, .text, .metadata],
            destination: .remote(url: server.url, provider: .openAICompatible))
        let sentRequest = request
        let (data, _) = try await PrivacyTrace.$context.withValue(context) {
            try await PrivacyHTTPTrace.upload(sentRequest, fromFile: file, operation: operation,
                textQueryItems: ["initial_prompt"], textInBody: false)
        }
        let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(response["methods"] as? [String] == (status == 307 ? ["POST", "POST", "POST"] : ["POST", "GET", "GET"]))
        #expect(response["lengths"] as? [Int] == (status == 307 ? [payload.count, payload.count, payload.count] : [payload.count, 0, 0]))
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.attempts.count == 3)
        #expect(receipt.attempts.map(\.outcome) == [.redirected, .redirected, .succeeded])
        #expect(receipt.attempts.map(\.operation.destination.hostname) == ["127.0.0.1", "127.0.0.1", "127.0.0.1"])
        #expect(receipt.attempts.map { $0.operation.data.contains(.recordingAudio) } == [true, status == 307, status == 307])
        #expect(receipt.attempts.map { $0.operation.data.contains(.text) } == [true, true, false])
        #expect(!receipt.hasGaps)
        let evidence = try String(contentsOf: context.receiptURL, encoding: .utf8)
        for secret in ["initial_prompt", "private-redirect-text", "synthetic recording bytes", "/middle", "/finish"] {
            #expect(!evidence.contains(secret))
        }
    }

    @Test(arguments: [true, false], ["data", "file", "stream", "untraced"])
    func crossOriginRedirectIsRejectedWithOrWithoutTracing(tracing: Bool, transport: String) async throws {
        let server = try ReceiptRedirectServer(status: 307, crossOrigin: true)
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blocked-redirect-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context: PrivacyTrace.Context? = tracing ? .init(receiptURL: folder.appendingPathComponent("receipt.json"), store: PrivacyReceiptStore()) : nil
        var request = URLRequest(url: server.url)
        request.httpMethod = "POST"
        request.httpBody = Data("synthetic recording".utf8)
        request.setValue("synthetic-secret", forHTTPHeaderField: "X-API-Key")
        let sentRequest = request
        let operation = PrivacyOperation(stage: .analysis, data: [.text], destination: .remote(url: server.url, provider: .custom))
        let file = folder.appendingPathComponent("synthetic.wav")
        try sentRequest.httpBody!.write(to: file)
        let (body, response) = try await PrivacyTrace.$context.withValue(context) {
            switch transport {
            case "untraced":
                return try await PrivacyHTTPTrace.untracedData(for: sentRequest)
            case "file":
                var upload = sentRequest
                upload.httpBody = nil
                return try await PrivacyHTTPTrace.upload(upload, fromFile: file, operation: operation)
            case "stream":
                let (bytes, response, trace) = try await PrivacyHTTPTrace.bytes(for: sentRequest, operation: operation)
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                await trace?.finish(response: response)
                return (data, response)
            default: return try await PrivacyHTTPTrace.data(for: sentRequest, operation: operation)
            }
        }
        let captured = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(captured["methods"] as? [String] == ["POST"])
        #expect(captured["keys"] as? [String] == ["synthetic-secret"])
        #expect((response as? HTTPURLResponse)?.statusCode == 307)
        if let context, transport != "untraced" {
            let receipt = try #require(try await context.store.load(from: context.receiptURL))
            #expect(receipt.attempts.count == 1)
            #expect(receipt.attempts.first?.outcome == .failed)
        }
    }

    @Test func cancellationAfterRedirectCompletesTheCorrectAttempt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-cancel-hop-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = URL(string: "https://first.invalid")!
        let context = PrivacyTrace.Context(receiptURL: folder.appendingPathComponent("receipt.json"), store: PrivacyReceiptStore())
        let trace = PrivacyHTTPTrace(operation: .init(stage: .transcription, data: [.recordingAudio],
            destination: .remote(url: first, provider: .custom)), context: context)
        await trace.start()
        var redirected = URLRequest(url: URL(string: "https://second.invalid")!)
        redirected.httpMethod = "POST"
        await trace.redirect(to: redirected)
        await trace.finish(error: CancellationError())
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.attempts.map(\.outcome) == [.redirected, .cancelled])
        #expect(receipt.attempts.last?.operation.destination.hostname == "second.invalid")
    }

    @Test func unobservedRedirectDoesNotAttributeFinalSuccessToOriginalHost() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-unobserved-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = URL(string: "https://first.invalid")!
        let context = PrivacyTrace.Context(receiptURL: folder.appendingPathComponent("receipt.json"),
            store: PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps")))
        let operation = PrivacyOperation(stage: .transcription, data: [.recordingAudio],
            destination: .remote(url: first, provider: .custom))
        let response = HTTPURLResponse(url: URL(string: "https://unobserved.invalid")!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!
        _ = try await PrivacyTrace.$context.withValue(context) {
            try await PrivacyHTTPTrace.upload(URLRequest(url: first), fromFile: folder.appendingPathComponent("unused.wav"),
                operation: operation, using: { _, _ in (Data(), response) })
        }
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.hasGaps)
        #expect(receipt.attempts.count == 1)
        #expect(receipt.attempts[0].outcome == .started)
        #expect(receipt.attempts[0].finishedAt == nil)
    }
}

/// Synthetic, loopback-only receiver. Using a real HTTP server verifies that
/// URLSession invokes the per-task delegate and actually replays/removes bodies.
/// Python is already a repository build/test dependency (beta versioning tools).
private final class ReceiptRedirectServer {
    let process: Process
    let url: URL

    init(status: Int, crossOrigin: Bool = false) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", Self.script, String(status), crossOrigin ? "localhost" : "127.0.0.1"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while line.count < 16 {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data([10]) { break }
            line.append(byte)
        }
        guard let port = Int(String(decoding: line, as: UTF8.self)), port > 0 else {
            if process.isRunning { process.terminate() }
            throw CocoaError(.fileReadUnknown)
        }
        self.process = process
        self.url = URL(string: "http://127.0.0.1:\(port)/start?initial_prompt=private-redirect-text")!
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private static let script = #"""
import http.server, json, sys
status = int(sys.argv[1])
methods, lengths, keys = [], [], []
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self): self.reply()
    def do_GET(self): self.reply()
    def reply(self):
        length = int(self.headers.get('Content-Length', '0'))
        self.rfile.read(length)
        methods.append(self.command)
        keys.append(self.headers.get("X-API-Key"))
        lengths.append(length)
        if self.path.startswith('/start'):
            self.send_response(status)
            self.send_header('Location', f'http://{sys.argv[2]}:{self.server.server_port}/middle?initial_prompt=private-redirect-text')
        elif self.path.startswith('/middle'):
            self.send_response(status)
            self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/finish')
        else:
            self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps({'methods': methods, 'lengths': lengths, 'keys': keys}).encode())
with http.server.HTTPServer(('127.0.0.1', 0), Handler) as server:
    print(server.server_port, flush=True)
    server.serve_forever()
"""#
}
