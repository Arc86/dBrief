import Foundation
import Testing
@testable import dBrief

@Suite("Hosted transcription upload limits")
struct RemoteUploadPolicyTests {
    @Test("Hosted OpenAI and Groq split above the direct-upload boundary", arguments: [
        "https://api.openai.com", "https://eu.api.openai.com", "https://API.OPENAI.COM./",
        "https://api.groq.com/openai",
    ])
    func hostedChunkBoundaries(baseURL: String) throws {
        let policy = RemoteUploadPolicy(endpoint: endpoint(baseURL), configuredMaxUploadMB: 100)
        #expect(try policy.chunkSize(forFileBytes: 24_999_999) == nil)
        #expect(try policy.chunkSize(forFileBytes: 25_000_000) == nil)
        #expect(try policy.chunkSize(forFileBytes: 25_000_001) == 25_000_000)
        #expect(throws: RemoteUploadError.self) { try policy.validateFileByteCount(25_000_001) }
    }

    @Test("Native provider limits honor inclusive and exclusive API boundaries")
    func nativeBoundaries() throws {
        let deepgram = RemoteUploadPolicy(endpoint: endpoint("https://api.eu.deepgram.com", provider: .deepgram), configuredMaxUploadMB: 1)
        #expect(try deepgram.chunkSize(forFileBytes: 2_000_000_000) == nil)
        #expect(throws: RemoteUploadError.self) { try deepgram.chunkSize(forFileBytes: 2_000_000_001) }
        let elevenLabs = RemoteUploadPolicy(endpoint: endpoint("https://api.elevenlabs.io", provider: .elevenLabs), configuredMaxUploadMB: 1)
        #expect(try elevenLabs.chunkSize(forFileBytes: 4_999_999_999) == nil)
        #expect(throws: RemoteUploadError.self) { try elevenLabs.chunkSize(forFileBytes: 5_000_000_000) }
    }

    @Test("Custom hosts retain the configured threshold, including lookalike hostnames", arguments: [
        "https://transcription.example.com", "http://localhost:8000", "https://api.openai.com.example.com",
        "https://example.com/api.openai.com", "https://api.openai.com@example.com",
        "https://notapi.openai.com", "https://api.openai.com:8443",
    ])
    func selfHosted(baseURL: String) throws {
        let policy = RemoteUploadPolicy(endpoint: endpoint(baseURL), configuredMaxUploadMB: 80)
        #expect(try policy.chunkSize(forFileBytes: 80 * 1_024 * 1_024) == nil)
        #expect(try policy.chunkSize(forFileBytes: 80 * 1_024 * 1_024 + 1) == 80 * 1_024 * 1_024)
        try policy.validateFileByteCount(100_000_000)
    }

    @Test("Native custom endpoints and whisper-asr keep their whole-file behavior")
    func nativeCustomEndpoints() throws {
        for endpoint in [
            endpoint("https://deepgram.internal", provider: .deepgram),
            endpoint("https://scribe.internal", provider: .elevenLabs),
            endpoint("http://localhost:9000/asr"),
            endpoint("https://asr.example.com"), // Existing whisper-asr URL detection.
        ] {
            let policy = RemoteUploadPolicy(endpoint: endpoint, configuredMaxUploadMB: 1)
            #expect(try policy.chunkSize(forFileBytes: 6_000_000_000) == nil)
        }
    }

    @Test("A smaller configured limit wins and extreme saved values cannot overflow")
    func configuredThreshold() throws {
        let hosted = RemoteUploadPolicy(endpoint: endpoint("https://api.openai.com"), configuredMaxUploadMB: 1)
        #expect(try hosted.chunkSize(forFileBytes: 1_048_576) == nil)
        #expect(try hosted.chunkSize(forFileBytes: 1_048_577) == 1_048_576)
        let extreme = RemoteUploadPolicy(endpoint: endpoint("https://custom.example"), configuredMaxUploadMB: Int.max)
        #expect(try extreme.chunkSize(forFileBytes: Int64.max) == nil)
        let invalid = RemoteUploadPolicy(endpoint: endpoint("https://custom.example"), configuredMaxUploadMB: Int.min)
        #expect(try invalid.chunkSize(forFileBytes: 1_048_577) == 1_048_576)
    }

    @Test("Hosted diarization models stay in one request to preserve speaker identities")
    func diarizationSafety() throws {
        var endpoint = endpoint("https://api.openai.com")
        endpoint.modelName = "gpt-4o-transcribe-diarize"
        let policy = RemoteUploadPolicy(endpoint: endpoint, configuredMaxUploadMB: 1)
        #expect(try policy.chunkSize(forFileBytes: 25_000_000) == nil)
        #expect(throws: RemoteUploadError.self) { try policy.chunkSize(forFileBytes: 25_000_001) }
    }

    @Test("File size checks refresh after a source changes and reject directories")
    func fileSizeRefresh() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("size-refresh-\(UUID())")
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try RemoteUploadPolicy.fileByteCount(file) == 1)
        try Data([1, 2, 3]).write(to: file)
        #expect(try RemoteUploadPolicy.fileByteCount(file) == 3)
        #expect(throws: RemoteUploadError.self) {
            try RemoteUploadPolicy.fileByteCount(FileManager.default.temporaryDirectory)
        }
    }

    private func endpoint(_ baseURL: String, provider: Endpoint.Provider = .openAICompatible) -> Endpoint {
        Endpoint(name: "Fixture", baseURL: baseURL, modelName: "whisper-1", provider: provider)
    }
}
