import Testing
import Foundation
@testable import dBrief

@Suite("MarkdownInsightsUpdater")
struct MarkdownInsightsUpdaterTests {
    private let sample = """
    ---
    title: "Sync"
    date: 2026-06-09 10:00
    tags:
      - old-tag
    duration: "12:00"
    sentiment: "Neutral"
    type: "meeting"
    ---

    ## 📝 Summary

    Old summary text.

    ## ✅ Action Items

    - [ ] Old item

    ## 🏷️ Tags

    #oldtag

    **Sentiment:** Neutral

    ---
    ## 💬 Transcript

    **[00:00]** Hello world.

    """

    private func makeInsights(summary: String, items: [String], tags: [String]) -> RecordingInsights {
        RecordingInsights(version: 1, summary: summary, actionItems: items,
                          tags: tags, sentiment: "Neutral", markdownPath: nil)
    }

    @Test("replaces summary, preserves transcript")
    func summaryReplaced() {
        let insights = makeInsights(summary: "New summary.", items: ["Old item"], tags: ["oldtag"])
        let result = MarkdownInsightsUpdater.update(markdown: sample, with: insights)
        #expect(result.contains("New summary."))
        #expect(!result.contains("Old summary text."))
        #expect(result.contains("## 💬 Transcript"))
        #expect(result.contains("Hello world."))
    }

    @Test("replaces action items")
    func actionItemsReplaced() {
        let insights = makeInsights(summary: "Old summary text.", items: ["First", "Second"], tags: ["oldtag"])
        let result = MarkdownInsightsUpdater.update(markdown: sample, with: insights)
        #expect(result.contains("- [ ] First"))
        #expect(result.contains("- [ ] Second"))
        #expect(!result.contains("- [ ] Old item"))
    }

    @Test("updates body tags and frontmatter tags")
    func tagsReplaced() {
        let insights = makeInsights(summary: "Old summary text.", items: ["Old item"], tags: ["new one", "second"])
        let result = MarkdownInsightsUpdater.update(markdown: sample, with: insights)
        // body: sanitized via ObsidianTag (lowercased, whitespace -> hyphen, #-prefixed)
        #expect(result.contains("#new-one #second"))
        #expect(!result.contains("#oldtag"))
        // frontmatter: whitespace -> hyphen, under the tags: key
        #expect(result.contains("  - new-one"))
        #expect(result.contains("  - second"))
        #expect(!result.contains("  - old-tag"))
    }

    @Test("leaves markdown unchanged when a section is absent")
    func missingSectionSafe() {
        let noActionItems = """
        ---
        title: "X"
        ---

        ## 📝 Summary

        Some summary.

        """
        let insights = makeInsights(summary: "Updated.", items: ["Won't appear"], tags: [])
        let result = MarkdownInsightsUpdater.update(markdown: noActionItems, with: insights)
        #expect(result.contains("Updated."))
        // No Action Items header existed, so nothing is inserted for it.
        #expect(!result.contains("## ✅ Action Items"))
    }
}
