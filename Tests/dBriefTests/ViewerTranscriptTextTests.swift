import Foundation
import SwiftUI
import Testing
@testable import dBrief

@Suite("Transcript text rendering")
@MainActor
struct ViewerTranscriptTextTests {
    @Test func joinedUnicodeSearchSpanRetainsItsHighlight() {
        let first = RichSegment(start: 0, end: 1, text: "Café 👩🏽‍💻", originalText: "Café 👩🏽‍💻", speakerId: "A")
        let second = RichSegment(start: 1, end: 2, text: "dat zei je", originalText: "dat zei je", speakerId: "A")
        let turn = SpeakerTurn(speakerId: "A", segments: [first, second])
        let result = TranscriptSearch.search(turns: [(turn.id, turn.text)], query: "👩🏽‍💻 dat")
        let palette = ViewerThemeResolver.resolve(mode: .light, sourceHex: "#1268F5", nonNeon: false)
        let paragraphs = ViewerTranscriptText.makeParagraphs(text: turn.text, ranges: turn.readingParagraphRanges,
            matches: result.matches, currentMatchIndex: 0, palette: palette)
        #expect(paragraphs.count == 1)
        #expect(String(paragraphs[0].characters) == turn.text)
        let start = paragraphs[0].characters.index(paragraphs[0].characters.startIndex, offsetBy: 5)
        #expect(paragraphs[0][start..<paragraphs[0].characters.index(after: start)].backgroundColor == palette.primary.color)
        let firstCharacter = paragraphs[0].characters.startIndex
        #expect(paragraphs[0][firstCharacter..<paragraphs[0].characters.index(after: firstCharacter)].backgroundColor == nil)
    }

    @Test func paragraphBreaksPreserveTextAndLaterSearchOffsets() {
        let turn = SpeakerTurn(speakerId: "A", segments: [
            RichSegment(start: 0, end: 1, text: "First part.", originalText: "First part.", speakerId: "A"),
            RichSegment(start: 4, end: 5, text: "Later match", originalText: "Later match", speakerId: "A"),
        ])
        let result = TranscriptSearch.search(turns: [(turn.id, turn.text)], query: "Later")
        let palette = ViewerThemeResolver.resolve(mode: .darkPaper, sourceHex: "#1268F5", nonNeon: true)
        let paragraphs = ViewerTranscriptText.makeParagraphs(text: turn.text, ranges: turn.readingParagraphRanges,
            matches: result.matches, currentMatchIndex: 0, palette: palette)
        #expect(paragraphs.map { String($0.characters) } == ["First part.", "Later match"])
        let start = paragraphs[1].characters.startIndex
        #expect(paragraphs[1][start..<paragraphs[1].characters.index(after: start)].backgroundColor == palette.primary.color)
    }
}
