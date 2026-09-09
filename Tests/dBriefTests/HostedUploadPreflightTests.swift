import Foundation
import AVFoundation
import Testing
@testable import dBrief

private actor PreflightUploads {
    private(set) var calls = 0
    private(set) var bodyPrefixes: [String] = []
    func send(_ request: URLRequest, _ file: URL) throws -> (Data, URLResponse) {
        calls += 1
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        bodyPrefixes.append(String(decoding: try input.read(upToCount: 512) ?? Data(), as: UTF8.self))
        return (Data(#"{"text":"ok"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Hosted upload preflight")
struct HostedUploadPreflightTests {
    @Test("Oversized native audio is rejected before any request without deleting source", arguments: [false, true])
    func nativeRejectsBeforeTransport(elevenLabs: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("limit-\(UUID()).wav")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        let size: UInt64 = elevenLabs ? 5_000_000_000 : 2_000_000_001
        try handle.truncate(atOffset: size) // Sparse file, no payload allocation.
        try handle.close()
        let uploads = PreflightUploads()
        let service = TranscriptionService(upload: { try await uploads.send($0, $1) })
        let endpoint = Endpoint(name: "Fixture", baseURL: elevenLabs ? "https://api.elevenlabs.io" : "https://api.deepgram.com",
                                modelName: elevenLabs ? "scribe_v1" : "nova-3", provider: elevenLabs ? .elevenLabs : .deepgram)
        await #expect(throws: RemoteUploadError.self) {
            _ = try await service.transcribe(fileURL: file, endpoint: endpoint, diarize: true)
        }
        #expect(await uploads.calls == 0)
        #expect(try RemoteUploadPolicy.fileByteCount(file) == Int64(size))
    }

    @Test("Missing audio fails locally without probing the provider")
    func missingSource() async throws {
        let uploads = PreflightUploads()
        let service = TranscriptionService(upload: { try await uploads.send($0, $1) })
        let endpoint = Endpoint(name: "Fixture", baseURL: "https://api.openai.com", modelName: "whisper-1")
        await #expect(throws: RemoteUploadError.self) {
            _ = try await service.transcribe(fileURL: URL(fileURLWithPath: "/missing-\(UUID()).wav"), endpoint: endpoint)
        }
        #expect(await uploads.calls == 0)
    }

    @Test("An exact hosted limit uses one whole-file request instead of splitting")
    func exactLimit() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("limit-\(UUID()).wav")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 25_000_000)
        try handle.close()
        let uploads = PreflightUploads()
        let service = TranscriptionService(upload: { try await uploads.send($0, $1) })
        let endpoint = Endpoint(name: "Fixture", baseURL: "https://api.openai.com", modelName: "fixture-\(UUID())")
        _ = try await service.transcribe(fileURL: file, endpoint: endpoint,
                                        chunking: .init(enabled: false, maxUploadMB: 100, overlapSeconds: 2, retryCount: 0))
        #expect(await uploads.calls == 2) // Format probe, then the original file.
        let prefixes = await uploads.bodyPrefixes
        #expect(prefixes.last?.contains("filename=\"\(file.lastPathComponent)\"") == true)
    }

    @Test("Real oversized hosted audio is split despite a larger configured limit and disabled toggle")
    func hostedCapOverridesConfiguration() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("limit-audio-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            try #require(buffer.floatChannelData)[0].update(repeating: 0, count: 16_000)
            let writer = try AVAudioFile(forWriting: file, settings: format.settings)
            for _ in 0..<400 { try writer.write(from: buffer) }
        }
        #expect(try RemoteUploadPolicy.fileByteCount(file) > 25_000_000)
        let uploads = PreflightUploads()
        let service = TranscriptionService(upload: { try await uploads.send($0, $1) })
        let endpoint = Endpoint(name: "Fixture", baseURL: "https://api.openai.com", modelName: "fixture-\(UUID())")
        _ = try await service.transcribe(fileURL: file, endpoint: endpoint,
                                        chunking: .init(enabled: false, maxUploadMB: 100, overlapSeconds: 2, retryCount: 0))
        #expect(await uploads.calls == 3) // Format probe, then two actual chunks.
        let prefixes = await uploads.bodyPrefixes
        #expect(prefixes.contains { $0.contains("filename=\"chunk_0.m4a\"") })
        #expect(prefixes.contains { $0.contains("filename=\"chunk_1.m4a\"") })
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
