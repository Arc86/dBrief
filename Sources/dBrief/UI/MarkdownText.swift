import SwiftUI

/// Lightweight block-level Markdown renderer for AI-generated text (chat replies
/// and recording summaries).
///
/// SwiftUI's `Text` only auto-renders *inline* Markdown (bold, italic, links),
/// so headings, bullet lists, and numbered lists would otherwise show as raw
/// `#`/`-`/`1.` syntax. This view parses the common block elements the model
/// emits into one attributed text value, delegating inline spans to `AttributedString`.
struct MarkdownText: View {
    // Only the source is stored: `init` runs on every parent re-render (e.g. each
    // tab switch), so parsing there re-rendered the whole summary each time. The
    // parse happens in `body`, which SwiftUI skips while these inputs are unchanged,
    // and goes through a cache for views that are rebuilt with the same text.
    private let text: String
    private let readingFont: Font?
    /// Link `[hh:mm:ss]` citations (chat answers) so they can seek the recording.
    private let linksTimestamps: Bool
    @Environment(\.uiTypography) private var typography

    init(_ text: String, readingFont: Font? = nil, linksTimestamps: Bool = false) {
        self.text = text
        self.readingFont = readingFont
        self.linksTimestamps = linksTimestamps
    }

    var body: some View {
        let rendered = MarkdownRenderCache.shared.rendered(text, readingFont: readingFont,
                                                           linksTimestamps: linksTimestamps)
        // A single selectable text view avoids a nested SwiftUI layout graph for
        // every line when a streamed response becomes formatted after Stop.
        Text(readingFont != nil ? rendered : Self.appHeadingFonts(in: rendered, typography: typography))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func render(_ text: String, readingFont: Font? = nil, linksTimestamps: Bool = false) -> AttributedString {
        var result = AttributedString()
        for (index, block) in parse(text).enumerated() {
            if index > 0 { result += AttributedString("\n") }
            switch block {
            case .heading(let level, let text):
                var heading = inline(text)
                heading.font = readingFont.map { $0.weight(.semibold) } ?? headingFont(level)
                heading[MarkdownHeadingLevel.self] = level
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
        return linksTimestamps ? ChatTimestampLink.linked(result) : result
    }

    /// Adjust the cached heading spans when UI preferences change without parsing again.
    @MainActor
    static func appHeadingFonts(in rendered: AttributedString, typography: AppTypographyPreferences) -> AttributedString {
        var result = rendered
        for run in rendered.runs {
            guard let level = run[MarkdownHeadingLevel.self] else { continue }
            let style: AppFontStyle = switch level {
            case 1: .title3.bold()
            case 2: .headline
            default: .subheadline.bold()
            }
            result[run.range].font = style.resolve(using: typography)
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

private enum MarkdownHeadingLevel: AttributedStringKey {
    typealias Value = Int
    static let name = "dBrief.markdownHeadingLevel"
}

/// Parsed Markdown by source text and font, least-recently-used eviction.
@MainActor
final class MarkdownRenderCache {
    static let shared = MarkdownRenderCache()

    private struct Key: Hashable {
        let text: String
        let readingFont: Font?
        let linksTimestamps: Bool
    }

    private var entries: [Key: AttributedString] = [:]
    private var recency: [Key] = []
    private let limit: Int
    /// How many times text was actually parsed (for tests).
    private(set) var renderCount = 0

    init(limit: Int = 64) {
        self.limit = limit
    }

    func rendered(_ text: String, readingFont: Font?, linksTimestamps: Bool = false) -> AttributedString {
        let key = Key(text: text, readingFont: readingFont, linksTimestamps: linksTimestamps)
        if let cached = entries[key] {
            touch(key)
            return cached
        }
        renderCount += 1
        let result = MarkdownText.render(text, readingFont: readingFont, linksTimestamps: linksTimestamps)
        entries[key] = result
        touch(key)
        while recency.count > limit {
            entries[recency.removeFirst()] = nil
        }
        return result
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
