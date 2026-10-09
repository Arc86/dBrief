import Foundation

/// Surgically rewrites the AI-analysis sections of an existing markdown file
/// without touching the transcript, audio link, model info, or other content.
/// Used when the user edits the analysis in the transcript window.
enum MarkdownInsightsUpdater {

    static let summaryHeader = "## 📝 Summary"
    static let actionItemsHeader = "## ✅ Action Items"
    static let tagsHeader = "## 🏷️ Tags"
    static let askDBriefHeader = "## ✨ Ask dBrief"
    static let transcriptHeader = "## 💬 Transcript"

    /// Replaces the Ask dBrief section with `body`, or inserts it before the transcript
    /// (or at the end when the note has no transcript).
    static func upsertAskDBrief(markdown: String, body: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        let bodyLines = body.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.contains(askDBriefHeader) {
            replaceSection(in: &lines, header: askDBriefHeader, body: bodyLines, keepsBlankLines: true)
            return lines.joined(separator: "\n")
        }
        let section = [askDBriefHeader, ""] + bodyLines + [""]
        if let transcript = lines.firstIndex(of: transcriptHeader) {
            lines.insert(contentsOf: section, at: transcript)
        } else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            lines += [""] + section
        }
        return lines.joined(separator: "\n")
    }

    static func update(markdown: String, with insights: RecordingInsights) -> String {
        var lines = markdown.components(separatedBy: "\n")

        // Body sections (only replaced if the header exists).
        replaceSection(in: &lines, header: summaryHeader,
                       body: [insights.summary.trimmingCharacters(in: .whitespacesAndNewlines)])
        replaceSection(in: &lines, header: actionItemsHeader,
                       body: insights.actionItems.map { "- [ ] \($0)" })
        replaceSection(in: &lines, header: tagsHeader, body: [bodyTagsLine(insights.tags)])

        // Frontmatter tags list.
        updateFrontmatterTags(in: &lines, tags: insights.tags)

        return lines.joined(separator: "\n")
    }

    /// Replaces the content lines between `header` and the next section boundary
    /// (a line starting with `## ` or a `---` line, or end-of-file) with a blank
    /// line, `body`, and a trailing blank line. No-op if the header is absent or
    /// `body` is empty.
    private static func replaceSection(in lines: inout [String], header: String, body: [String],
                                       keepsBlankLines: Bool = false) {
        guard let headerIndex = lines.firstIndex(of: header) else { return }
        let nonEmptyBody = keepsBlankLines ? body : body.filter { !$0.isEmpty }
        guard !nonEmptyBody.isEmpty else { return }

        var end = headerIndex + 1
        while end < lines.count {
            let line = lines[end]
            if line.hasPrefix("## ") || line == "---" { break }
            end += 1
        }
        // Replace [headerIndex+1, end) with: "", body..., ""
        let replacement = [""] + nonEmptyBody + [""]
        lines.replaceSubrange((headerIndex + 1)..<end, with: replacement)
    }

    /// `#tag` tokens, sanitized for Obsidian (matches MarkdownGenerator).
    private static func bodyTagsLine(_ tags: [String]) -> String {
        ObsidianTag.sanitizeAll(tags).map { "#\($0)" }.joined(separator: " ")
    }

    /// Replaces the `tags:` block inside the YAML frontmatter (the region before
    /// the second `---`). If `tags:` is absent and there are tags, inserts a block
    /// after the `date:` line (or after the opening `---` if no `date:`).
    private static func updateFrontmatterTags(in lines: inout [String], tags: [String]) {
        guard lines.first == "---",
              let closingOffset = lines.dropFirst().firstIndex(of: "---") else { return }
        let closingIndex = closingOffset // index into `lines` (dropFirst preserves indices)

        let tagLines = ObsidianTag.sanitizeAll(tags).map { "  - \($0)" }

        if let tagsKeyIndex = lines[1..<closingIndex].firstIndex(of: "tags:") {
            // Remove existing `  - ` list lines following `tags:`.
            var end = tagsKeyIndex + 1
            while end < closingIndex, lines[end].hasPrefix("  - ") {
                end += 1
            }
            if tagLines.isEmpty {
                // Remove the now-empty `tags:` key too.
                lines.replaceSubrange(tagsKeyIndex..<end, with: [])
            } else {
                lines.replaceSubrange((tagsKeyIndex + 1)..<end, with: tagLines)
            }
        } else if !tagLines.isEmpty {
            // Insert after `date:` if present, else right after the opening `---`.
            let insertAfter = lines[1..<closingIndex].firstIndex(where: { $0.hasPrefix("date:") }) ?? 0
            lines.insert(contentsOf: ["tags:"] + tagLines, at: insertAfter + 1)
        }
    }
}
