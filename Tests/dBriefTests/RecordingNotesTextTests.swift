import Foundation
import Testing
@testable import dBrief

/// Three "Copy" buttons copied three different things, and History's "Copy summary"
/// looked for "## Summary" while the Markdown says "## 📝 Summary".
@Suite struct RecordingNotesTextTests {
    @Test func notesAreSummaryThenActionItems() {
        let text = RecordingNotesText.compose(summary: "We agreed on Q3.", actionItems: ["Send deck", "- Book room"],
                                              transcript: "Long transcript")
        #expect(text == "## Summary\nWe agreed on Q3.\n\n## Action Items\n- Send deck\n- Book room")
    }

    @Test func withoutAnalysisTheTranscriptIsCopied() {
        #expect(RecordingNotesText.compose(summary: nil, actionItems: [], transcript: "Hello") == "Hello")
        #expect(RecordingNotesText.compose(summary: nil, actionItems: nil, transcript: nil) == nil)
    }

    @Test func savedNotesAreReadFromTheInsightsSidecarFirst() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("meeting.m4a")
        let insights = RecordingInsights(summary: "From sidecar", actionItems: ["Follow up"], tags: [],
                                         sentiment: "Neutral", generatedTitle: nil, markdownPath: nil)
        try JSONEncoder().encode(insights).write(to: audio.deletingPathExtension().appendingPathExtension("insights.json"))
        #expect(await RecordingNotesText.load(for: audio) == "## Summary\nFrom sidecar\n\n## Action Items\n- Follow up")
    }

    @Test func olderRecordingsFallBackToTheMarkdownSummarySection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("old.m4a")
        try "# Old\n\n## 📝 Summary\nThe old summary.\n\n## 🏷️ Tags\n#a".write(
            to: audio.deletingPathExtension().appendingPathExtension("md"), atomically: true, encoding: .utf8)
        #expect(await RecordingNotesText.load(for: audio) == "## Summary\nThe old summary.")
    }
}
