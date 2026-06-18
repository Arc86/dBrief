import Testing
@testable import dBrief

private func seg(_ start: Double, _ end: Double, _ speaker: String) -> RichSegment {
    RichSegment(start: start, end: end, text: "", originalText: "", speakerId: speaker)
}

struct SpeakerSnippetTests {
    @Test("Picks the longest turn for the speaker")
    func longestTurn() {
        let t = RichTranscript(segments: [
            seg(0, 1, "A"),       // 1s
            seg(2, 9, "B"),       // 7s (B's longest)
            seg(10, 12, "A"),     // 2s (A's longest)
            seg(13, 14, "B"),     // 1s
        ])
        let a = SpeakerSnippet.representative(for: "A", in: t)
        #expect(a?.start == 10 && a?.end == 12)
    }

    @Test("Caps the snippet to maxLength from the turn start")
    func capsLength() {
        let t = RichTranscript(segments: [seg(5, 30, "B")]) // 25s turn
        let r = SpeakerSnippet.representative(for: "B", in: t, maxLength: 6)
        #expect(r?.start == 5 && r?.end == 11)
    }

    @Test("Nil when the speaker has no segment")
    func noSegment() {
        let t = RichTranscript(segments: [seg(0, 1, "A")])
        #expect(SpeakerSnippet.representative(for: "Z", in: t) == nil)
    }
}
