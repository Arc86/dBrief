import Testing
@testable import dBrief

/// Obsidian tag validity is guaranteed at the write boundary, independent of the AI
/// prompt or engine. These lock the sanitizer so exported Markdown can't carry a
/// malformed tag regardless of what the model returns.
struct ObsidianTagTests {

    @Test("Lowercases and hyphenates whitespace")
    func lowercaseAndHyphenate() {
        #expect(ObsidianTag.sanitize("Project Management") == "project-management")
        #expect(ObsidianTag.sanitize("  Q3   Review ") == "q3-review")
    }

    @Test("Strips a leading hash and disallowed special characters")
    func stripsSpecials() {
        #expect(ObsidianTag.sanitize("#budget") == "budget")
        #expect(ObsidianTag.sanitize("R&D") == "rd")
        #expect(ObsidianTag.sanitize("C++") == "c")
        #expect(ObsidianTag.sanitize("client: acme") == "client-acme")
    }

    @Test("Keeps Obsidian-legal separators incl. nested-tag slash")
    func keepsLegalSeparators() {
        #expect(ObsidianTag.sanitize("project/alpha") == "project/alpha")
        #expect(ObsidianTag.sanitize("sprint_planning") == "sprint_planning")
        #expect(ObsidianTag.sanitize("follow-up") == "follow-up")
    }

    @Test("Collapses separator runs and trims edges")
    func collapsesAndTrims() {
        #expect(ObsidianTag.sanitize("a -- b") == "a-b")
        #expect(ObsidianTag.sanitize("-leading-") == "leading")
        // A run of mixed separators collapses to one hyphen (single '/' is kept above).
        #expect(ObsidianTag.sanitize("a // b") == "a-b")
    }

    @Test("Rejects empty and purely-numeric tags")
    func rejectsInvalid() {
        #expect(ObsidianTag.sanitize("") == nil)
        #expect(ObsidianTag.sanitize("   ") == nil)
        #expect(ObsidianTag.sanitize("###") == nil)
        #expect(ObsidianTag.sanitize("2024") == nil)
        #expect(ObsidianTag.sanitize("123-456") == nil)
    }

    @Test("Keeps non-ASCII letters for non-English meetings")
    func keepsUnicodeLetters() {
        #expect(ObsidianTag.sanitize("Begroting") == "begroting")
        #expect(ObsidianTag.sanitize("café") == "café")
    }

    @Test("sanitizeAll drops invalid entries and de-duplicates in order")
    func sanitizeAllDedupes() {
        let result = ObsidianTag.sanitizeAll(["Budget", "budget", "  ", "2024", "Q3 Review", "q3 review"])
        #expect(result == ["budget", "q3-review"])
    }
}
