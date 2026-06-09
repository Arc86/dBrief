import Testing
import Foundation
@testable import dBrief

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
}
