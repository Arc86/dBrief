import Foundation
@testable import dBrief
import Testing

struct TranscriptStoreTests {
    @Test("load throws when no sidecar file exists")
    func loadNonExistent() async {
        let store = TranscriptStore()
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).richtranscript.json")
        await #expect(throws: (any Error).self) {
            try await store.load(from: url)
        }
    }

    @Test("save and load round-trip preserves segments and version")
    func saveAndLoad() async throws {
        let store = TranscriptStore()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("test.richtranscript.json")
        let transcript = RichTranscript(
            segments: [
                RichSegment(start: 0, end: 1.5, text: "Hello", originalText: "Hello"),
                RichSegment(start: 1.5, end: 3.0, text: "World", originalText: "World"),
            ]
        )

        try await store.save(transcript, to: url)
        let loaded = try await store.load(from: url)

        #expect(loaded.segments.count == 2)
        #expect(loaded.segments[0].text == "Hello")
        #expect(loaded.segments[1].text == "World")
        #expect(loaded.version == 1)
    }

    @Test("schema version field is preserved across encode/decode")
    func schemaVersionPreserved() async throws {
        let store = TranscriptStore()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("version.richtranscript.json")
        var transcript = RichTranscript(segments: [])
        transcript.version = 1

        try await store.save(transcript, to: url)
        let loaded = try await store.load(from: url)
        #expect(loaded.version == 1)
    }
}
