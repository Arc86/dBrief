import Foundation
import AVFoundation
import Testing
@testable import dBrief

private actor UploadCapture {
    struct Attempt: Sendable {
        let request: URLRequest
        let url: URL
        let bytes: Data
    }
    private(set) var attempts: [Attempt] = []
    let statuses: [Int]
    init(statuses: [Int] = []) { self.statuses = statuses }

    func send(_ request: URLRequest, file: URL) throws -> (Data, URLResponse) {
        attempts.append(Attempt(request: request, url: file, bytes: try Data(contentsOf: file)))
        let status = statuses.indices.contains(attempts.count - 1) ? statuses[attempts.count - 1] : 200
        let json: String
        if status != 200 {
            json = #"{"error":"unsupported response_format"}"#
        } else if request.url?.path.hasSuffix("listen") == true {
            json = #"{"results":{"channels":[{"alternatives":[{"transcript":"Hello","words":[]}]}]}}"#
        } else {
            json = #"{"text":"Hello","segments":[{"start":0,"end":1,"text":"Hello","words":[{"word":"Hello","start":0.1,"end":0.5,"probability":0.9}]}],"language_code":"en","words":[]}"#
        }
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Transcription file uploads")
struct TranscriptionUploadTests {
    @Test(arguments: ["deepgram", "elevenLabs"])
    func blankProviderModelUsesTheSameSentAndPersistedDefault(kind: String) async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("default-model-\(UUID()).wav")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        var endpoint = endpoint(kind: kind)
        endpoint.modelName = ""
        let frozen = endpoint
        let capture = UploadCapture()
        let service = TranscriptionService(upload: { try await capture.send($0, file: $1) })
        let output = try await ProcessingPipeline().transcribe(.init(audioURL: audio, segmentURLs: []),
            options: .init(removeFillerWords: false, ignoredSegments: [], modelName: TranscriptionService.modelName(for: frozen)),
            using: { try await service.transcribe(fileURL: $0.url, endpoint: frozen) })
        let attempt = try #require(await capture.attempts.last)
        let model = try #require(output.transcription.modelName)
        if kind == "deepgram" {
            #expect(model == "nova-3")
            let query = URLComponents(url: attempt.request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "model", value: model)))
        } else {
            #expect(model == "scribe_v1")
            let body = String(decoding: attempt.bytes, as: UTF8.self)
            #expect(body.contains("name=\"model_id\"\r\n\r\n\(model)"))
        }
    }

    @Test("All remote adapters send audio through a file and preserve their request contract",
          arguments: ["deepgram", "elevenLabs", "whisperASR", "openAI"])
    func providerRequests(kind: String) async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("upload-test-\(UUID()).wav")
        let bytes = Data([0, 255, 42, 13, 10])
        try bytes.write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let endpoint = endpoint(kind: kind)
        let capture = UploadCapture()
        let service = TranscriptionService(upload: { try await capture.send($0, file: $1) })
        let result = try await service.transcribe(fileURL: audio, endpoint: endpoint, language: "nl", initialPrompt: "Names & context", diarize: true)
        #expect(result.text == "Hello")
        let attempts = await capture.attempts
        #expect(attempts.count == (kind == "openAI" ? 2 : 1))
        let attempt = try #require(attempts.last)
        #expect(attempt.request.httpMethod == "POST")
        #expect(attempt.request.httpBody == nil)
        #expect(attempt.request.httpBodyStream == nil)
        #expect(attempt.request.timeoutInterval == 300)
        #expect(try Data(contentsOf: audio) == bytes)
        for sent in attempts where sent.url != audio {
            #expect(!FileManager.default.fileExists(atPath: sent.url.deletingLastPathComponent().path))
        }
        let query = URLComponents(url: attempt.request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if kind == "deepgram" {
            #expect(attempt.url == audio)
            #expect(attempt.bytes == bytes)
            #expect(attempt.request.value(forHTTPHeaderField: "Authorization") == "Token test-key")
            #expect(attempt.request.value(forHTTPHeaderField: "Content-Type") == "audio/wav")
            #expect(query.contains(URLQueryItem(name: "diarize", value: "true")))
            #expect(query.contains(URLQueryItem(name: "language", value: "nl")))
        } else {
            #expect(attempt.bytes.range(of: bytes) != nil)
            let body = String(decoding: attempt.bytes, as: UTF8.self)
            #expect(body.contains("filename=\"\(audio.lastPathComponent)\""))
            #expect(attempt.request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            if kind == "elevenLabs" {
                #expect(attempt.request.value(forHTTPHeaderField: "xi-api-key") == "test-key")
                #expect(body.contains("name=\"model_id\"\r\n\r\nsystran/faster-whisper"))
                #expect(body.contains("name=\"language_code\"\r\n\r\nnl"))
                #expect(body.contains("name=\"diarize\"\r\n\r\ntrue"))
            } else {
                #expect(attempt.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
                if kind == "whisperASR" {
                    #expect(body.contains("name=\"audio_file\""))
                    #expect(query.contains(URLQueryItem(name: "initial_prompt", value: "Names & context")))
                    #expect(query.contains(URLQueryItem(name: "language", value: "nl")))
                } else {
                    #expect(body.contains("name=\"model\"\r\n\r\nsystran/faster-whisper"))
                    #expect(body.contains("name=\"prompt\"\r\n\r\nNames & context"))
                    #expect(body.contains("name=\"timestamp_granularities[]\"\r\n\r\nsegment"))
                    #expect(body.contains("name=\"timestamp_granularities[]\"\r\n\r\nword"))
                }
            }
        }
    }

    @Test("Format fallback rebuilds a complete file body and cleans up every attempt")
    func fallback() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("upload-test-\(UUID()).wav")
        let bytes = Data([1, 2, 3, 4, 5])
        try bytes.write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let capture = UploadCapture(statuses: [200, 400, 200])
        let service = TranscriptionService(upload: { try await capture.send($0, file: $1) })
        let result = try await service.transcribe(fileURL: audio, endpoint: endpoint(kind: "openAI"))
        #expect(result.text == "Hello")
        let attempts = await capture.attempts
        try #require(attempts.count == 3)
        for sent in attempts.dropFirst() {
            #expect(sent.bytes.range(of: bytes) != nil)
            #expect(!FileManager.default.fileExists(atPath: sent.url.path))
        }
        #expect(String(decoding: attempts[1].bytes, as: UTF8.self).contains("\r\n\r\nverbose_json\r\n"))
        #expect(String(decoding: attempts[2].bytes, as: UTF8.self).contains("\r\n\r\njson\r\n"))
    }

    @Test("Cancelled format probing stops before any audio upload")
    func cancellationStopsProbes() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-probe-\(UUID()).wav")
        try Data([1]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let capture = UploadCapture()
        let service = TranscriptionService(upload: {
            _ = try await capture.send($0, file: $1)
            throw CancellationError()
        })
        await #expect(throws: CancellationError.self) {
            _ = try await service.transcribe(fileURL: audio, endpoint: endpoint(kind: "openAI"))
        }
        let attempts = await capture.attempts
        #expect(attempts.count == 1)
        #expect(attempts.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    }

    @Test("Server retries remain bounded and each failed attempt releases its body")
    func retryLimitAndCleanup() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("upload-test-\(UUID()).wav")
        let bytes = Data([3, 1, 4, 1, 5])
        try bytes.write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let capture = UploadCapture(statuses: [200, 503, 503, 200])
        let service = TranscriptionService(upload: { try await capture.send($0, file: $1) })
        let context = PrivacyTrace.Context(receiptURL: PrivacyReceiptStore.sidecarURL(for: audio), store: PrivacyReceiptStore())
        defer { try? FileManager.default.removeItem(at: context.receiptURL) }
        await PrivacyTrace.$context.withValue(context) {
            await #expect(throws: TranscriptionError.self) {
                _ = try await service.transcribe(fileURL: audio, endpoint: endpoint(kind: "openAI"),
                    chunking: .init(enabled: true, maxUploadMB: 15, overlapSeconds: 2, retryCount: 1))
            }
        }
        #expect(try await context.store.load(from: context.receiptURL)?.attempts.map(\.outcome) == [.succeeded, .failed, .failed])
        let attempts = await capture.attempts
        #expect(attempts.count == 3) // One probe and two actual attempts.
        for sent in attempts.dropFirst() {
            #expect(sent.bytes.range(of: bytes) != nil)
        }
        #expect(attempts.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
        #expect(try Data(contentsOf: audio) == bytes)
    }

    @Test("Cancellation following a server failure prevents a retry")
    func cancellationPreventsRetry() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("upload-test-\(UUID()).wav")
        try Data([1]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let capture = UploadCapture(statuses: [200, 503, 200])
        let service = TranscriptionService(upload: { request, file in
            let response = try await capture.send(request, file: file)
            if (response.1 as? HTTPURLResponse)?.statusCode == 503 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return response
        })
        let endpoint = endpoint(kind: "openAI")
        let task = Task { try await service.transcribe(fileURL: audio, endpoint: endpoint) }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let attempts = await capture.attempts
        #expect(attempts.count == 2)
        #expect(attempts.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    }

    @Test("Real audio chunks upload from files, preserve time offsets, and stop on cancellation", arguments: [false, true])
    func chunkedUpload(cancelFirstChunk: Bool) async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("upload-chunks-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        // 65 seconds of Float32 PCM exceeds 1 MiB. The existing chunker's 30s
        // minimum and 2s overlap produce starts at 0, 28, and 56 seconds.
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            try #require(buffer.floatChannelData)[0].update(repeating: 0, count: 16_000)
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            for _ in 0..<65 { try file.write(from: buffer) }
        }
        let capture = UploadCapture()
        let service = TranscriptionService(upload: { request, file in
            let response = try await capture.send(request, file: file)
            if cancelFirstChunk, await capture.attempts.count == 2 {
                throw URLError(.cancelled)
            }
            return response
        })
        let endpoint = endpoint(kind: "openAI")
        let chunking = TranscriptionService.ChunkingConfiguration(enabled: true, maxUploadMB: 1, overlapSeconds: 2, retryCount: 0)
        let context = PrivacyTrace.Context(receiptURL: PrivacyReceiptStore.sidecarURL(for: audio), store: PrivacyReceiptStore())
        defer { try? FileManager.default.removeItem(at: context.receiptURL) }
        if cancelFirstChunk {
            await PrivacyTrace.$context.withValue(context) {
                await #expect(throws: URLError(.cancelled)) {
                    _ = try await service.transcribe(fileURL: audio, endpoint: endpoint, chunking: chunking)
                }
            }
        } else {
            let result = try await PrivacyTrace.$context.withValue(context) {
                try await service.transcribe(fileURL: audio, endpoint: endpoint, chunking: chunking)
            }
            #expect(result.segments.map(\.start) == [0, 28, 56])
            #expect(result.segments.map(\.end) == [1, 29, 57])
            #expect(result.segments.compactMap { $0.words?.first?.start } == [0.1, 28.1, 56.1])
            #expect(result.segments.compactMap { $0.words?.first?.end } == [0.5, 28.5, 56.5])
        }
        let attempts = await capture.attempts
        #expect(attempts.count == (cancelFirstChunk ? 2 : 4))
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.attempts.count == attempts.count)
        #expect(receipt.attempts.first?.operation.stage == .formatProbe)
        #expect(receipt.attempts.dropFirst().allSatisfy { $0.operation.stage == .transcription })
        #expect(receipt.attempts.last?.outcome == (cancelFirstChunk ? .cancelled : .succeeded))
        for (index, sent) in attempts.dropFirst().enumerated() {
            #expect(sent.request.httpBody == nil)
            #expect(String(decoding: sent.bytes, as: UTF8.self).contains("filename=\"chunk_\(index).m4a\""))
            #expect(sent.bytes.count > 100)
        }
        #expect(attempts.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test("Receipts follow actual provider uploads and format fallback without retaining prompts",
          arguments: ["deepgram", "elevenLabs", "whisperASR", "openAI"])
    func privacyEvidence(kind: String) async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-upload-\(UUID()).wav")
        let receiptURL = PrivacyReceiptStore.sidecarURL(for: audio)
        defer {
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: receiptURL)
        }
        try Data([1, 2, 3, 4]).write(to: audio)
        let capture = UploadCapture(statuses: kind == "openAI" ? [200, 400, 200] : [])
        let service = TranscriptionService(upload: { try await capture.send($0, file: $1) })
        let endpoint = endpoint(kind: kind)
        let context = PrivacyTrace.Context(receiptURL: receiptURL, store: PrivacyReceiptStore())
        _ = try await PrivacyTrace.$context.withValue(context) {
            try await service.transcribe(fileURL: audio, endpoint: endpoint, initialPrompt: "Private meeting vocabulary")
        }
        let receipt = try #require(try await context.store.load(from: receiptURL))
        #expect(receipt.attempts.count == (kind == "openAI" ? 3 : 1))
        #expect(receipt.attempts.allSatisfy { $0.runID == context.runID })
        #expect(receipt.attempts.allSatisfy { $0.operation.destination.hostname == endpoint.transcriptionURL?.host?.lowercased() })
        #expect(receipt.attempts.last?.operation.data.contains(.recordingAudio) == true)
        #expect(receipt.attempts.last?.outcome == .succeeded)
        #expect(receipt.attempts.last?.operation.destination.model == (kind == "whisperASR" ? nil : endpoint.modelName))
        if kind == "openAI" {
            #expect(receipt.attempts.map(\.outcome) == [.succeeded, .failed, .succeeded])
            #expect(receipt.attempts.first?.operation.stage == .formatProbe)
            #expect(receipt.attempts.first?.operation.data.contains(.syntheticAudio) == true)
            #expect(receipt.attempts.first?.operation.data.contains(.recordingAudio) == false)
            #expect(receipt.attempts.allSatisfy { $0.operation.data.contains(.text) })
            #expect(receipt.attempts.map(\.operation.responseFormat) == [.verboseJSON, .verboseJSON, .json])
        }
        let evidence = try String(contentsOf: receiptURL, encoding: .utf8)
        for privateValue in ["Private meeting vocabulary", "test-key", audio.lastPathComponent, "Fixture"] {
            #expect(!evidence.contains(privateValue))
        }
    }

    @Test("Native receipts record the model defaults actually sent", arguments: ["deepgram", "elevenLabs"])
    func privacyNativeModelDefault(kind: String) async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-model-\(UUID()).wav")
        let context = PrivacyTrace.Context(receiptURL: PrivacyReceiptStore.sidecarURL(for: audio), store: PrivacyReceiptStore())
        defer {
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: context.receiptURL)
        }
        try Data([1]).write(to: audio)
        var endpoint = endpoint(kind: kind)
        endpoint.modelName = ""
        let capture = UploadCapture()
        let service = TranscriptionService(upload: { try await capture.send($0, file: $1) })
        let configured = endpoint
        _ = try await PrivacyTrace.$context.withValue(context) {
            try await service.transcribe(fileURL: audio, endpoint: configured)
        }
        #expect(try await context.store.load(from: context.receiptURL)?.attempts.first?.operation.destination.model
            == (kind == "deepgram" ? "nova-3" : "scribe_v1"))
    }

    @Test("Receipt cancellation is distinct from server failure and preflight creates no upload evidence")
    func privacyCancellationAndPreflight() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-cancel-\(UUID()).wav")
        let receiptURL = PrivacyReceiptStore.sidecarURL(for: audio)
        defer {
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: receiptURL)
        }
        let context = PrivacyTrace.Context(receiptURL: receiptURL, store: PrivacyReceiptStore())
        let service = TranscriptionService(upload: { _, _ in throw URLError(.cancelled) })
        await PrivacyTrace.$context.withValue(context) {
            await #expect(throws: (any Error).self) {
                _ = try await service.transcribe(fileURL: audio, endpoint: endpoint(kind: "deepgram"))
            }
        }
        #expect(try await context.store.load(from: receiptURL) == nil)
        try Data([1]).write(to: audio)
        await PrivacyTrace.$context.withValue(context) {
            await #expect(throws: URLError(.cancelled)) {
                _ = try await service.transcribe(fileURL: audio, endpoint: endpoint(kind: "deepgram"))
            }
        }
        let receipt = try #require(try await context.store.load(from: receiptURL))
        #expect(receipt.attempts.count == 1)
        #expect(receipt.attempts[0].outcome == .cancelled)
    }

    private func endpoint(kind: String) -> Endpoint {
        Endpoint(name: "Fixture", baseURL: "https://\(UUID().uuidString).invalid" + (kind == "whisperASR" ? "/asr" : ""),
                 modelName: "systran/faster-whisper", apiKey: "test-key",
                 provider: kind == "deepgram" ? .deepgram : kind == "elevenLabs" ? .elevenLabs : .openAICompatible)
    }
}
