import Testing
import SwiftUI
@testable import dBrief

@Suite("Markdown text rendering")
@MainActor
struct MarkdownTextRenderingTests {
    @Test("Headings and lists retain readable text and inline formatting")
    func formattedBlocks() {
        let result = MarkdownText.render("# Heading\n\n- **Bold item**\n12. *Numbered item*\nPlain text")
        #expect(String(result.characters) == "Heading\n\n• Bold item\n12. Numbered item\nPlain text")
        #expect(result.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(result.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    }

    @Test("UI typography updates heading spans without replacing inline emphasis")
    func appHeadingFamily() {
        let rendered = MarkdownText.render("# Heading\nA **bold** explanation")
        let typography = AppTypographyPreferences(readingFont: .monospace, fontSize: 18)
        let result = MarkdownText.appHeadingFonts(in: rendered, typography: typography)
        #expect(String(result.characters) == String(rendered.characters))
        #expect(result.runs.first?.font == AppFontStyle.title3.bold().resolve(using: typography))
        #expect(result.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(result.runs.last?.font == nil)
    }

    @Test("A stopped multiline reply remains one attributed text value")
    func longReply() {
        let reply = (1...200).map { "**Point \($0)**\n- A detailed explanation with **emphasis**.\n" }.joined(separator: "\n")
        let result = MarkdownText.render(reply)
        #expect(String(result.characters).contains("Point 200\n• A detailed explanation with emphasis."))
        #expect(result.characters.filter { $0 == "\n" }.count == reply.filter { $0 == "\n" }.count)
    }
}
