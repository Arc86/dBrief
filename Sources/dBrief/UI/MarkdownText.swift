import SwiftUI

/// Lightweight block-level Markdown renderer for AI-generated text (chat replies
/// and recording summaries).
///
/// SwiftUI's `Text` only auto-renders *inline* Markdown (bold, italic, links),
/// so headings, bullet lists, and numbered lists would otherwise show as raw
/// `#`/`-`/`1.` syntax. This view parses the common block elements the model
/// emits and renders each line, delegating inline spans to `AttributedString`.
struct MarkdownText: View {
    private let blocks: [Block]

    init(_ text: String) {
        self.blocks = MarkdownText.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text)
                        .font(headingFont(level))
                        .padding(.top, 2)
                case .bullet(let text):
                    listRow(marker: "•", text: text)
                        .padding(.leading, 14)
                case .numbered(let number, let text):
                    listRow(marker: "\(number).", text: text)
                case .paragraph(let text):
                    inline(text)
                case .spacer:
                    Color.clear.frame(height: 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .foregroundStyle(.secondary)
            inline(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.bold()
        case 2: return .headline
        default: return .subheadline.bold()
        }
    }

    /// Renders inline Markdown spans (`**bold**`, `*italic*`, `` `code` ``, links).
    private func inline(_ text: String) -> Text {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let attributed = (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
        return Text(attributed)
    }

    // MARK: Parsing

    private enum Block {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case numbered(number: String, text: String)
        case paragraph(text: String)
        case spacer
    }

    private static func parse(_ text: String) -> [Block] {
        text.components(separatedBy: "\n").map { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return .spacer }

            // Heading: one-to-six leading '#'s followed by a space.
            if let hash = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let level = line[hash].filter { $0 == "#" }.count
                let content = String(line[hash.upperBound...])
                return .heading(level: level, text: content)
            }

            // Bullet list: '-', '*', or '+' followed by a space.
            if let bullet = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                return .bullet(text: String(line[bullet.upperBound...]))
            }

            // Numbered list: digits, then '.', then a space.
            if let number = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let marker = line[number].trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ".", with: "")
                return .numbered(number: marker, text: String(line[number.upperBound...]))
            }

            return .paragraph(text: line)
        }
    }
}
