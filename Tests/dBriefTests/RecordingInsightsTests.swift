import Testing
import Foundation
@testable import dBrief
import dBriefWire

@Suite("RecordingInsights")
struct RecordingInsightsTests {
    @Test("encodes and decodes round-trip")
    func roundTrip() throws {
        let original = RecordingInsights(
            version: 1,
            summary: "We discussed the roadmap.",
            actionItems: ["Email the deck", "Book a follow-up"],
            tags: ["roadmap", "planning"],
            sentiment: "Positive",
            markdownPath: "/tmp/notes/2026-06-09 - Sync.md"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecordingInsights.self, from: data)
        #expect(decoded == original)
    }

    @Test("copy text includes all non-empty sections")
    func copyTextFull() {
        let insights = RecordingInsights(
            version: 1,
            summary: "A short summary.",
            actionItems: ["Do X", "Do Y"],
            tags: ["alpha", "beta"],
            sentiment: "Neutral",
            markdownPath: nil
        )
        let text = insights.plainTextForCopy()
        #expect(text.contains("Summary"))
        #expect(text.contains("A short summary."))
        #expect(text.contains("- Do X"))
        #expect(text.contains("- Do Y"))
        #expect(text.contains("#alpha #beta"))
        #expect(text.contains("Sentiment: Neutral"))
    }

    @Test("copy text omits empty sections")
    func copyTextOmitsEmpty() {
        let insights = RecordingInsights(
            version: 1,
            summary: "Only a summary.",
            actionItems: [],
            tags: [],
            sentiment: "",
            markdownPath: nil
        )
        let text = insights.plainTextForCopy()
        #expect(text.contains("Only a summary."))
        #expect(!text.contains("Action Items"))
        #expect(!text.contains("Tags"))
        #expect(!text.contains("Sentiment:"))
    }

    @Test func insightsWithoutPartNotesStillDecode() throws {
        let legacy = #"{"version":1,"summary":"S","actionItems":[],"tags":[],"sentiment":"Neutral"}"#
        let insights = try JSONDecoder().decode(RecordingInsights.self, from: Data(legacy.utf8))
        #expect(insights.partNotes == nil)
    }

    @Test func partNotesRoundTripThroughLocalInsightsResult() throws {
        let notes = [ChunkNotes(keyPoints: ["k"], decisions: [], actionItems: ["[A] to x"], people: ["A"])]
        let result = LocalInsightsResult(titleConcept: "T", summary: "S", actionItems: [], tags: [], sentiment: "Neutral", partNotes: notes)
        let decoded = try LocalInsightsDecoder.decodeAndNormalize(String(decoding: JSONEncoder().encode(result), as: UTF8.self))
        #expect(decoded.partNotes == notes)
    }

    @Test func resultWithoutPartNotesOmitsTheKey() throws {
        let result = LocalInsightsResult(summary: "S", actionItems: [], tags: [], sentiment: "Neutral")
        #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("part_notes"))
    }

    @Test func partNotesSurviveEditsAndMarkdownUpdate() async throws {
        let notes = [ChunkNotes(keyPoints: ["k"], decisions: ["d"], actionItems: ["[A] to x"], people: ["A"])]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).insights.json")
        defer { try? FileManager.default.removeItem(at: url) }
        var baseline = RecordingInsights(summary: "Old", actionItems: ["[A] to x"], tags: ["t"], sentiment: "Neutral", markdownPath: nil)
        baseline.partNotes = notes
        let store = InsightsStore()
        try await store.save(baseline, to: url)
        var edited = baseline
        edited.summary = "New summary"
        let saved = try await store.saveAnalysisEdit(edited, basedOn: baseline, to: url)
        #expect(saved.partNotes == notes)
        _ = try await store.setActionCompleted("[A] to x", completed: true, at: url)
        try await store.setExportLink(URL(fileURLWithPath: "/tmp/x.md"), generatedTitle: "T", at: url)
        #expect(try await store.load(from: url)?.partNotes == notes)
        // The markdown updater only rewrites text; it must not need or touch part notes.
        let md = MarkdownInsightsUpdater.update(markdown: "## \u{1F4DD} Summary\n\nOld\n", with: saved)
        #expect(md.contains("New summary"))
    }
}
