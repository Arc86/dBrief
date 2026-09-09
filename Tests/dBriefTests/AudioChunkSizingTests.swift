import AVFoundation
import Foundation
import Testing
@testable import dBrief

@Suite("Audio chunk byte budgets")
struct AudioChunkSizingTests {
    @Test("Encoded chunks fit the byte budget even when the initial duration estimate does not")
    func verifiesExportedBytes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try writeNoise(to: source, seconds: 30)
        let originalBytes = try Data(contentsOf: source)
        let output = root.appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let chunks = try await AudioChunker().chunkAudio(fileURL: source, maxUploadBytes: 16_000, overlapSeconds: 15, tempDirectory: output)
        #expect(chunks.count > 1)
        #expect(chunks.first?.startSeconds == 0)
        #expect(chunks.last?.endSeconds == 30)
        for (index, chunk) in chunks.enumerated() {
            #expect(try RemoteUploadPolicy.fileByteCount(chunk.url) <= 16_000)
            #expect(chunk.endSeconds > chunk.startSeconds)
            if index > 0 {
                #expect(chunk.startSeconds > chunks[index - 1].startSeconds)
                #expect(chunk.startSeconds <= chunks[index - 1].endSeconds)
            }
        }
        #expect(try Data(contentsOf: source) == originalBytes)
    }

    @Test("An impossible byte budget fails with a bounded error and keeps the source")
    func impossibleBudget() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try writeNoise(to: source, seconds: 2)
        let output = root.appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        await #expect(throws: AudioChunkerError.self) {
            _ = try await AudioChunker().chunkAudio(fileURL: source, maxUploadBytes: 1, overlapSeconds: 15, tempDirectory: output)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-sizing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeNoise(to url: URL, seconds: Int) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try #require(buffer.floatChannelData)[0]
        var state: UInt32 = 42
        for i in 0..<16_000 {
            state = state &* 1_664_525 &+ 1_013_904_223
            samples[i] = Float(Int32(bitPattern: state)) / Float(Int32.max) * 0.3
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for _ in 0..<seconds { try file.write(from: buffer) }
    }
}
