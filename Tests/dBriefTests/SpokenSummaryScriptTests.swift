import Testing
@testable import dBrief

@Suite struct SpokenSummaryScriptTests {
    @Test func stripsLeadingListMarkers() {
        let out = SpokenSummaryScript.clean("- First point\n* Second point\n1. Third point")
        #expect(out == "First point\nSecond point\nThird point")
    }

    @Test func stripsHeadingHashesKeepingText() {
        #expect(SpokenSummaryScript.clean("## Overview\nBody text") == "Overview\nBody text")
    }

    @Test func removesBoldAndItalicAndBacktickMarkers() {
        #expect(SpokenSummaryScript.clean("This is **bold** and *italic* and `code`.")
                == "This is bold and italic and code.")
    }

    @Test func removesCodeFenceMarkersKeepingInnerText() {
        #expect(SpokenSummaryScript.clean("```\nhello world\n```") == "hello world")
    }

    @Test func collapsesExcessBlankLinesAndTrims() {
        #expect(SpokenSummaryScript.clean("\n\nLine one\n\n\n\nLine two\n\n") == "Line one\n\nLine two")
    }

    @Test func leavesPlainProseUnchanged() {
        let prose = "Here is a normal sentence. And another one."
        #expect(SpokenSummaryScript.clean(prose) == prose)
    }

    // MARK: - Speech normalization

    @Test func normalizesEllipsisGlyphToSentenceStop() {
        #expect(SpokenSummaryScript.clean("Well… anyway, we shipped it.")
                == "Well. anyway, we shipped it.")
    }

    @Test func normalizesDottedEllipsisToSentenceStop() {
        #expect(SpokenSummaryScript.clean("wait...what happened") == "wait. what happened")
    }

    @Test func convertsEmDashAsideToCommaPause() {
        #expect(SpokenSummaryScript.clean("First point — second point") == "First point, second point")
    }

    @Test func keepsHyphenatedWords() {
        #expect(SpokenSummaryScript.clean("We agreed on a follow-up next week.")
                == "We agreed on a follow-up next week.")
    }

    @Test func stripsEmoji() {
        #expect(SpokenSummaryScript.clean("Great meeting 🎉 today") == "Great meeting today")
    }

    @Test func collapsesDoubleSpacesAndSpaceBeforePunctuation() {
        #expect(SpokenSummaryScript.clean("Too   many    spaces here .") == "Too many spaces here.")
    }

    @Test func keepsDigitsWhenStrippingEmoji() {
        #expect(SpokenSummaryScript.clean("There were 3 action items.") == "There were 3 action items.")
    }
}
