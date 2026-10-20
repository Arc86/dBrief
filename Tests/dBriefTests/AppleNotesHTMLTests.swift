import Foundation
import Testing
@testable import dBrief

@Suite("Apple Notes body")
struct AppleNotesHTMLTests {
    private func bundle(summary: String? = "**Overview**\nWe met.\n\n- One\n- Two",
                        actions: [String] = ["- Send the deck", "No action items identified"]) -> IntegrationContentBundle {
        IntegrationContentBundle(title: "Sync <Q3>", createdAt: Date(timeIntervalSince1970: 1_790_000_000), durationSeconds: 3_725,
            audioFileURL: URL(fileURLWithPath: "/tmp/a.m4a"), transcript: "Alice: hi\nBob: hello", summary: summary,
            actionItems: actions, tags: ["Q3 planning"], sentiment: "Positive", markdown: nil, calendarEvent: nil)
    }

    @Test("Title heading first, then sections in note order with the transcript last")
    func layout() throws {
        let html = AppleNotesHTML.body(for: bundle(), fields: [.transcript, .summary, .actionItems, .tags, .sentiment],
                                       locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(html.hasPrefix("<h1>Sync &lt;Q3&gt;</h1>"))
        let order = try ["<h2>Summary</h2>", "<h2>Action items</h2>", "<h2>Tags</h2>", "<h2>Sentiment</h2>", "<h2>Transcript</h2>"]
            .map { try #require(html.range(of: $0)).lowerBound }
        #expect(order == order.sorted())
        #expect(html.contains("<h3>Overview</h3>"))
        #expect(html.contains("<ul><li>One</li><li>Two</li></ul>"))
        #expect(html.contains("<ul><li>Send the deck</li></ul>"))
        #expect(!html.contains("No action items identified"))
        #expect(!html.contains("**"))
        #expect(html.contains("#q3-planning"))
        #expect(html.contains("<div>Alice: hi</div>"))
    }

    @Test("Inline styles and links become HTML, text is escaped")
    func inlineStyles() {
        let html = AppleNotesHTML.render(NotionMarkdown.blocks(from: "A **bold** and *it* `x<y` [site](https://e.com/?a=1&b=2)"))
        #expect(html.contains("<b>bold</b>"))
        #expect(html.contains("<i>it</i>"))
        #expect(html.contains("<tt>x&lt;y</tt>"))
        #expect(html.contains("<a href=\"https://e.com/?a=1&amp;b=2\">site</a>"))
    }

    @Test("Unselected or empty fields are left out")
    func fieldsRespected() {
        let html = AppleNotesHTML.body(for: bundle(summary: nil, actions: []), fields: [.summary, .actionItems])
        #expect(!html.contains("<h2>"))
    }
}
