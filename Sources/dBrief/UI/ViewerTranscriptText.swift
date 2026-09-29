import SwiftUI

/// Playback decoration changes independently of selectable transcript text.
/// Equatable input keeps native text layout intact while the parent/player ticks.
struct ViewerTranscriptText: View, Equatable {
    let text: String
    let paragraphRanges: [Range<Int>]
    let matches: [TranscriptSearch.Match]
    let currentMatchIndex: Int
    @Environment(\.viewerPalette) private var palette

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.paragraphRanges == rhs.paragraphRanges
            && lhs.matches == rhs.matches && lhs.currentMatchIndex == rhs.currentMatchIndex
    }

    var body: some View {
        ForEach(Array(Self.makeParagraphs(text: text, ranges: paragraphRanges,
            matches: matches, currentMatchIndex: currentMatchIndex, palette: palette).enumerated()), id: \.offset) { _, paragraph in
            ViewerReadingParagraph(text: paragraph)
        }
    }

    static func makeParagraphs(text: String, ranges: [Range<Int>],
        matches: [TranscriptSearch.Match], currentMatchIndex: Int, palette: ViewerPalette) -> [AttributedString] {
        var highlighted = AttributedString(text)
        let count = highlighted.characters.count
        for match in matches {
            guard match.location >= 0, match.length > 0,
                  match.location <= count, match.length <= count - match.location else { continue }
            let start = highlighted.characters.index(highlighted.characters.startIndex, offsetBy: match.location)
            let end = highlighted.characters.index(start, offsetBy: match.length)
            let current = match.globalIndex == currentMatchIndex
            highlighted[start..<end].backgroundColor = current ? palette.primary.color : palette.selected.color
            highlighted[start..<end].foregroundColor = current ? palette.onPrimary.color : palette.accentText.color
        }
        let characters = highlighted.characters
        let paragraphs = ranges.compactMap { range -> AttributedString? in
            guard range.lowerBound >= 0, range.lowerBound < count else { return nil }
            let start = characters.index(characters.startIndex, offsetBy: range.lowerBound)
            let end = characters.index(characters.startIndex, offsetBy: min(range.upperBound, count))
            let paragraph = AttributedString(highlighted[start..<end])
            return String(paragraph.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : paragraph
        }
        return paragraphs.isEmpty ? [highlighted] : paragraphs
    }
}
