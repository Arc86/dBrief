import Foundation
import Testing
@testable import dBrief

@Suite("Notion Markdown conversion")
struct NotionMarkdownTests {
    private func types(_ blocks: [[String: Any]]) -> [String] { blocks.compactMap { $0["type"] as? String } }

    private func runs(_ block: [String: Any]) -> [[String: Any]] {
        let type = block["type"] as? String ?? ""
        return (block[type] as? [String: Any])?["rich_text"] as? [[String: Any]] ?? []
    }

    private func text(_ block: [String: Any]) -> String {
        runs(block).compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined()
    }

    private func annotations(_ run: [String: Any]) -> [String: Bool] {
        (run["annotations"] as? [String: Bool]) ?? [:]
    }

    @Test func blockStructureBecomesNotionBlocks() {
        let markdown = """
        **Overview**
        This is a post-qualifying analysis.
        It continues here.

        ## Discussion Points
        - First **point**
        * Second point
        1. Numbered one
        2) Numbered two
        - [ ] Open task
        - [x] Done task
        > A quote
        ---
        Last line.
        """
        let blocks = NotionMarkdown.blocks(from: markdown)
        #expect(types(blocks) == ["heading_3", "paragraph", "heading_3", "bulleted_list_item", "bulleted_list_item",
                                  "numbered_list_item", "numbered_list_item", "to_do", "to_do", "quote", "divider",
                                  "paragraph"])
        #expect(text(blocks[0]) == "Overview")
        #expect(text(blocks[1]) == "This is a post-qualifying analysis.\nIt continues here.")
        #expect(text(blocks[2]) == "Discussion Points")
        #expect(text(blocks[3]) == "First point")
        #expect(text(blocks[6]) == "Numbered two")
        #expect((blocks[7]["to_do"] as? [String: Any])?["checked"] as? Bool == false)
        #expect((blocks[8]["to_do"] as? [String: Any])?["checked"] as? Bool == true)
        #expect(text(blocks[9]) == "A quote")
    }

    @Test func inlineStylesBecomeAnnotations() throws {
        let block = try #require(NotionMarkdown.blocks(from: "Plain **bold** and *italic*, `code`, ~~gone~~ and [a link](https://example.com).").first)
        let pieces = runs(block)
        let content = pieces.map { ($0["text"] as? [String: Any])?["content"] as? String ?? "" }
        #expect(content == ["Plain ", "bold", " and ", "italic", ", ", "code", ", ", "gone", " and ", "a link", "."])
        #expect(annotations(pieces[1])["bold"] == true)
        #expect(annotations(pieces[3])["italic"] == true)
        #expect(annotations(pieces[5])["code"] == true)
        #expect(annotations(pieces[7])["strikethrough"] == true)
        let link = (pieces[9]["text"] as? [String: Any])?["link"] as? [String: String]
        #expect(link == ["url": "https://example.com"])
        #expect(pieces[0]["annotations"] == nil)
    }

    @Test func unmatchedMarkersStayAsText() throws {
        let block = try #require(NotionMarkdown.blocks(from: "2 * 3 = 6 and a lone ** marker").first)
        #expect(text(block) == "2 * 3 = 6 and a lone ** marker")
    }

    @Test func longStyledTextStaysWithinNotionsLimits() throws {
        // A whole line in bold is a section label; bold inside a sentence stays bold.
        let long = "Intro **" + String(repeating: "word ", count: 900).trimmingCharacters(in: .whitespaces) + "**"
        let block = try #require(NotionMarkdown.blocks(from: long).first)
        #expect(block["type"] as? String == "paragraph")
        let pieces = runs(block)
        #expect(pieces.count > 2)
        #expect(pieces.allSatisfy { (($0["text"] as? [String: Any])?["content"] as? String ?? "").utf16.count <= NotionAPI.maxTextLength })
        #expect(pieces.dropFirst().allSatisfy { annotations($0)["bold"] == true })
    }

    @Test func notionLeavesTheTranscriptOutByDefault() {
        #expect(!NotionConfig().fields.contains(.transcript))
        #expect(NotionConfig().fields.contains(.summary))
    }
}
