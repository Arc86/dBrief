import Foundation
import dBriefWire
@testable import dBrief
import Testing

@MainActor
struct MarkdownGeneratorTests {
    private func makeRecording() -> Recording {
        let recording = Recording(
            fileURL: URL(fileURLWithPath: "/tmp/meeting.m4a"),
            meetingTitleDraft: "meeting",
            finalizedAudioURL: URL(fileURLWithPath: "/tmp/meeting.m4a")
        )
        recording.generatedTitle = "Quarterly Planning"
        recording.summary = "We planned the quarter."
        recording.tags = ["planning"]
        recording.transcription = TranscriptionResult(
            text: "Hello team. Sounds good.",
            segments: [
                TranscriptionResult.Segment(start: 0.0, end: 1.0, text: "Hello team.", speaker: "Speaker 1"),
                TranscriptionResult.Segment(start: 1.0, end: 2.0, text: "Sounds good.", speaker: "Speaker 2"),
            ],
            speakerCount: 2
        )
        recording.richTranscript = RichTranscript(
            segments: [],
            speakerLabels: [
                SpeakerLabel(id: "Speaker 1", displayName: "Alice"),
                SpeakerLabel(id: "Speaker 2", displayName: "Bob"),
            ]
        )
        return recording
    }

    @Test("render uses speaker display names and emits model frontmatter")
    func renderUsesDisplayNames() {
        let recording = makeRecording()
        let markdown = MarkdownGenerator().render(
            recording: recording,
            transcriptionEndpoint: Endpoint(name: "WhisperKit", baseURL: "", modelName: "large-v3 (CoreML)"),
            aiEndpoint: Endpoint(name: "Gemma", baseURL: "", modelName: "gemma-4-e4b (MLX)"),
            includeTranscript: true
        )

        // Speaker display names, not raw IDs, appear in the transcript section.
        #expect(markdown.contains("Alice:"))
        #expect(markdown.contains("Bob:"))
        #expect(!markdown.contains("Speaker 1:"))
        #expect(!markdown.contains("Speaker 2:"))

        // Model info lands in the frontmatter.
        #expect(markdown.contains("transcription_model: \"large-v3 (CoreML)\""))
        #expect(markdown.contains("ai_model: \"gemma-4-e4b (MLX)\""))
    }

    @Test("render reflects renamed speaker labels (post-hoc edit path)")
    func renderReflectsRename() {
        let recording = makeRecording()
        recording.richTranscript?.speakerLabels = [
            SpeakerLabel(id: "Speaker 1", displayName: "Alice Johnson"),
            SpeakerLabel(id: "Speaker 2", displayName: "Bob Smith"),
        ]
        let markdown = MarkdownGenerator().render(
            recording: recording,
            transcriptionEndpoint: nil,
            aiEndpoint: nil,
            includeTranscript: true
        )
        #expect(markdown.contains("Alice Johnson:"))
        #expect(markdown.contains("Bob Smith:"))
    }

    @Test("write overwrites a fixed URL even when the title changes")
    func writeOverwritesStablePath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outputURL = dir.appendingPathComponent("note.md")
        let recording = makeRecording()

        recording.generatedTitle = "First Title"
        let url1 = try MarkdownGenerator().write(
            recording: recording,
            to: outputURL,
            transcriptionEndpoint: nil,
            aiEndpoint: nil,
            includeTranscript: false
        )

        recording.generatedTitle = "Second Title"
        let url2 = try MarkdownGenerator().write(
            recording: recording,
            to: outputURL,
            transcriptionEndpoint: nil,
            aiEndpoint: nil,
            includeTranscript: false
        )

        #expect(url1 == outputURL)
        #expect(url2 == outputURL)
        let content = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(content.contains("title: \"Second Title\""))
        #expect(!content.contains("title: \"First Title\""))
    }
}
