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
}
