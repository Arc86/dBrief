import Foundation
@testable import dBrief
import Testing

struct TranscriptStoreTests {
    @Test("load returns nil when no sidecar exists")
    @MainActor
    func loadNonExistent() async {
        let store = TranscriptStore()
        let recording = Recording(
            fileURL: URL(fileURLWithPath: "/tmp/nonexistent.flac"),
            finalizedAudioURL: URL(fileURLWithPath: "/tmp/nonexistent.flac")
        )
        let result = await store.load(for: recording)
        #expect(result == nil)
    }

    @Test("save and load round-trip")
    @MainActor
    func saveAndLoad() async throws {
        let store = TranscriptStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let audioURL = tempDir.appendingPathComponent("test.recording.flac")
        try "dummy".write(to: audioURL, atomically: true, encoding: .utf8)

        let recording = Recording(
            fileURL: audioURL,
            finalizedAudioURL: audioURL
        )

        let transcript = RichTranscript(segments: [
            RichTranscript.Segment(start: 0, end: 1.5, text: "Hello world"),
            RichTranscript.Segment(start: 1.5, end: 3.0, text: "Goodbye world"),
        ])

        await store.save(transcript, for: recording)

        let loaded = await store.load(for: recording)
        #expect(loaded != nil)
        #expect(loaded?.segments.count == 2)
        #expect(loaded?.segments[0].text == "Hello world")
        #expect(loaded?.segments[1].text == "Goodbye world")
    }

    @Test("delete removes sidecar")
    @MainActor
    func deleteSidecar() async throws {
        let store = TranscriptStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let audioURL = tempDir.appendingPathComponent("test.recording.flac")
        try "dummy".write(to: audioURL, atomically: true, encoding: .utf8)

        let recording = Recording(
            fileURL: audioURL,
            finalizedAudioURL: audioURL
        )

        let transcript = RichTranscript(segments: [
            RichTranscript.Segment(start: 0, end: 1.0, text: "Test"),
        ])

        await store.save(transcript, for: recording)
        #expect(await store.exists(for: recording) == true)

        await store.delete(for: recording)
        #expect(await store.exists(for: recording) == false)
    }
}
