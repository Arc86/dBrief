import SwiftUI

/// Lightweight block-level Markdown renderer for AI-generated text (chat replies
/// and recording summaries).
///
/// SwiftUI's `Text` only auto-renders *inline* Markdown (bold, italic, links),
/// so headings, bullet lists, and numbered lists would otherwise show as raw
/// `#`/`-`/`1.` syntax. This view parses the common block elements the model
/// emits into one attributed text value, delegating inline spans to `AttributedString`.
struct MarkdownText: View {
    private let rendered: AttributedString

    init(_ text: String) {
        rendered = Self.render(text)
    }

    var body: some View {
        // A single selectable text view avoids a nested SwiftUI layout graph for
        // every line when a streamed response becomes formatted after Stop.
        Text(rendered)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func render(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, block) in parse(text).enumerated() {
            if index > 0 { result += AttributedString("\n") }
            switch block {
            case .heading(let level, let text):
                var heading = inline(text)
                heading.font = headingFont(level)
                result += heading
            case .bullet(let text):
                result += AttributedString("• ") + inline(text)
            case .numbered(let number, let text):
                result += AttributedString("\(number). ") + inline(text)
            case .paragraph(let text):
                result += inline(text)
            case .spacer:
                break
            }
        }
        return result
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.bold()
        case 2: return .headline
        default: return .subheadline.bold()
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: Parsing

    private enum Block {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case numbered(number: String, text: String)
        case paragraph(text: String)
        case spacer
    }

    // Compiled once — parse runs per line of every rendered message.
    private static let headingRegex = try! NSRegularExpression(pattern: #"^#{1,6}\s+"#)
    private static let bulletRegex = try! NSRegularExpression(pattern: #"^[-*+]\s+"#)
    private static let numberedRegex = try! NSRegularExpression(pattern: #"^\d+\.\s+"#)

    private static func prefixMatch(_ regex: NSRegularExpression, _ line: String) -> Range<String.Index>? {
        let ns = NSRange(line.startIndex..., in: line)
        guard let m = regex.firstMatch(in: line, range: ns), let r = Range(m.range, in: line) else { return nil }
        return r
    }

    private static func parse(_ text: String) -> [Block] {
        text.components(separatedBy: "\n").map { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return .spacer }

            // Heading: one-to-six leading '#'s followed by a space.
            if let hash = prefixMatch(headingRegex, line) {
                let level = line[hash].filter { $0 == "#" }.count
                let content = String(line[hash.upperBound...])
                return .heading(level: level, text: content)
            }

            // Bullet list: '-', '*', or '+' followed by a space.
            if let bullet = prefixMatch(bulletRegex, line) {
                return .bullet(text: String(line[bullet.upperBound...]))
            }

            // Numbered list: digits, then '.', then a space.
            if let number = prefixMatch(numberedRegex, line) {
                let marker = line[number].trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ".", with: "")
                return .numbered(number: marker, text: String(line[number.upperBound...]))
            }

            return .paragraph(text: line)
        }
    }
}
