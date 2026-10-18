import Foundation

/// Converts the Markdown that AI summaries use into Notion blocks: headings, a
/// line that is only `**bold**` (a common AI section label), bullets, numbered
/// items, `- [ ]` to-dos, quotes, dividers and paragraphs, with inline bold,
/// italic, code, strikethrough and links as rich-text annotations. Text runs are
/// split to Notion's 2,000-unit limit; anything it doesn't recognise stays text.
enum NotionMarkdown {
    static func blocks(from markdown: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        var paragraph: [String] = []
        func flush() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks += textBlocks("paragraph", text) }
            paragraph = []
        }
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if let block = structuralBlock(line) {
                flush()
                blocks += block
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    /// One block for a list item, quote or heading line; nil for paragraph text.
    private static func structuralBlock(_ line: String) -> [[String: Any]]? {
        if ["---", "***", "___"].contains(line) { return [["object": "block", "type": "divider", "divider": [:]]] }
        if let heading = line.wholeMatch(of: /#{1,6}\s+(.+)/) { return textBlocks("heading_3", String(heading.1)) }
        if let label = line.wholeMatch(of: /\*\*([^*]+)\*\*:?/) ?? line.wholeMatch(of: /__([^_]+)__:?/) {
            return textBlocks("heading_3", String(label.1))
        }
        if let todo = line.wholeMatch(of: /[-*+]\s+\[([ xX])\]\s+(.+)/) {
            return textBlocks("to_do", String(todo.2), extra: ["checked": todo.1 != " "])
        }
        if let bullet = line.wholeMatch(of: /[-*+•]\s+(.+)/) { return textBlocks("bulleted_list_item", String(bullet.1)) }
        if let number = line.wholeMatch(of: /\d+[.)]\s+(.+)/) { return textBlocks("numbered_list_item", String(number.1)) }
        if let quote = line.wholeMatch(of: />\s?(.*)/) { return textBlocks("quote", String(quote.1)) }
        return nil
    }

    /// Blocks of `type` holding `markdown`'s inline-styled text. A rich-text
    /// array holds at most 100 runs, so very long text continues in more blocks.
    static func textBlocks(_ type: String, _ markdown: String, extra: [String: Any] = [:]) -> [[String: Any]] {
        let runs = richText(markdown)
        guard !runs.isEmpty else { return [] }
        return stride(from: 0, to: runs.count, by: 100).map { start in
            var content: [String: Any] = ["rich_text": Array(runs[start..<min(start + 100, runs.count)])]
            content.merge(extra) { $1 }
            return ["object": "block", "type": type, type: content]
        }
    }

    private struct Style: Hashable {
        var bold = false, italic = false, code = false, strikethrough = false
        var link: String?
    }

    /// Notion rich-text runs for one line or paragraph of Markdown.
    static func richText(_ markdown: String) -> [[String: Any]] {
        var spans: [(text: String, style: Style)] = []
        parse(Substring(markdown), style: Style(), into: &spans)
        return spans.flatMap { span in
            NotionAPI.split(span.text, trimming: false).map { piece -> [String: Any] in
                var text: [String: Any] = ["content": piece]
                if let link = span.style.link { text["link"] = ["url": link] }
                var run: [String: Any] = ["type": "text", "text": text]
                let style = span.style
                if style.bold || style.italic || style.code || style.strikethrough {
                    var annotations: [String: Bool] = [:]
                    if style.bold { annotations["bold"] = true }
                    if style.italic { annotations["italic"] = true }
                    if style.code { annotations["code"] = true }
                    if style.strikethrough { annotations["strikethrough"] = true }
                    run["annotations"] = annotations
                }
                return run
            }
        }
    }

    /// Inline markers: `code`, [text](url), **bold**/__bold__, ~~strike~~,
    /// *italic*/_italic_. A marker without its closing pair is plain text.
    private static func parse(_ text: Substring, style: Style, into spans: inout [(text: String, style: Style)]) {
        var plain = ""
        var index = text.startIndex
        func emitPlain() {
            if !plain.isEmpty { append(plain, style, &spans) }
            plain = ""
        }
        while index < text.endIndex {
            let rest = text[index...]
            if !style.code, rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
                emitPlain()
                var code = style
                code.code = true
                append(String(rest[rest.index(after: rest.startIndex)..<close]), code, &spans)
                index = text.index(after: close)
                continue
            }
            if rest.hasPrefix("["), let match = rest.prefixMatch(of: /\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/) {
                emitPlain()
                var linked = style
                linked.link = String(match.2)
                parse(match.1, style: linked, into: &spans)
                index = match.range.upperBound
                continue
            }
            var matched = false
            for (marker, apply) in [("**", { (s: inout Style) in s.bold = true }), ("__", { (s: inout Style) in s.bold = true }),
                                    ("~~", { (s: inout Style) in s.strikethrough = true }),
                                    ("*", { (s: inout Style) in s.italic = true }), ("_", { (s: inout Style) in s.italic = true })] {
                guard rest.hasPrefix(marker) else { continue }
                let inner = rest.dropFirst(marker.count)
                // A closing marker must exist, and neither side may hug whitespace ("2 * 3").
                guard let first = inner.first, !first.isWhitespace,
                      let close = inner.range(of: marker),
                      close.lowerBound > inner.startIndex,
                      !inner[inner.index(before: close.lowerBound)].isWhitespace else { continue }
                emitPlain()
                var styled = style
                apply(&styled)
                parse(inner[..<close.lowerBound], style: styled, into: &spans)
                index = close.upperBound
                matched = true
                break
            }
            if matched { continue }
            plain.append(text[index])
            index = text.index(after: index)
        }
        emitPlain()
    }

    private static func append(_ text: String, _ style: Style, _ spans: inout [(text: String, style: Style)]) {
        guard !text.isEmpty else { return }
        if let last = spans.last, last.style == style {
            spans[spans.count - 1].text += text
        } else {
            spans.append((text, style))
        }
    }
}
