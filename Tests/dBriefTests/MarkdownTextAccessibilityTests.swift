import SwiftUI
import Testing
@testable import dBrief

@MainActor @Suite("Summary text for VoiceOver")
struct MarkdownTextAccessibilityTests {
    @Test func linesKeepTheirHeadingLevels() {
        let rendered = MarkdownText.render("# Summary\nWe agreed.\n\n## Next steps\n- Ship it")
        let lines = MarkdownText.accessibilityLines(rendered)
        #expect(lines.map { String($0.text.characters) } == ["Summary", "We agreed.", "Next steps", "• Ship it"])
        #expect(lines.map(\.headingLevel) == [1, nil, 2, nil])
    }

    @Test func plainTextIsOneLine() {
        let lines = MarkdownText.accessibilityLines(MarkdownText.render("Just one paragraph."))
        #expect(lines.count == 1)
        #expect(lines.first?.headingLevel == nil)
    }
}
