import Testing
@testable import dBrief

@Suite("SpeakerTurn merging")
struct SpeakerTurnTests {

    // Helper: build a minimal RichSegment without spelling out every default.
    private func seg(
        _ text: String,
        speaker: String?,
        start: Double = 0,
        end: Double = 1
    ) -> RichSegment {
        RichSegment(
            id: .init(),
            start: start,
            end: end,
            text: text,
            originalText: text,
            tokens: [],
            speakerId: speaker,
            isStarred: false,
            isEdited: false
        )
    }

    @Test func emptyTranscriptProducesNoTurns() {
        let t = RichTranscript(version: 1, segments: [], speakerLabels: [])
        #expect(t.speakerTurns().isEmpty)
    }

    @Test func singleSegmentIsOneTurn() {
        let t = RichTranscript(version: 1, segments: [seg("Hello", speaker: "A")], speakerLabels: [])
        let turns = t.speakerTurns()
        #expect(turns.count == 1)
        #expect(turns[0].text == "Hello")
        #expect(turns[0].speakerId == "A")
    }

    @Test func consecutiveSameSpeakerMerged() {
        let t = RichTranscript(version: 1, segments: [
            seg("Hello", speaker: "A", start: 0, end: 1),
            seg("world", speaker: "A", start: 1, end: 2),
        ], speakerLabels: [])
        let turns = t.speakerTurns()
        #expect(turns.count == 1)
        #expect(turns[0].text == "Hello world")
        #expect(turns[0].startTime == 0)
        #expect(turns[0].endTime == 2)
    }

    @Test func differentSpeakersNotMerged() {
        let t = RichTranscript(version: 1, segments: [
            seg("Hi", speaker: "A"),
            seg("Hey", speaker: "B"),
        ], speakerLabels: [])
        #expect(t.speakerTurns().count == 2)
    }

    @Test func alternatingTurnsPreserved() {
        let t = RichTranscript(version: 1, segments: [
            seg("A1", speaker: "A"),
            seg("B1", speaker: "B"),
            seg("A2", speaker: "A"),
        ], speakerLabels: [])
        let turns = t.speakerTurns()
        #expect(turns.count == 3)
        #expect(turns[0].speakerId == "A")
        #expect(turns[1].speakerId == "B")
        #expect(turns[2].speakerId == "A")
        #expect(turns[2].text == "A2")
    }

    @Test func nilSpeakerEachSegmentOwnTurn() {
        let t = RichTranscript(version: 1, segments: [
            seg("one", speaker: nil),
            seg("two", speaker: nil),
        ], speakerLabels: [])
        #expect(t.speakerTurns().count == 2)
    }

    @Test func trailingRunMerged() {
        // Last run must be appended even without a following different speaker.
        let t = RichTranscript(version: 1, segments: [
            seg("A1", speaker: "A"),
            seg("B1", speaker: "B"),
            seg("B2", speaker: "B"),
        ], speakerLabels: [])
        let turns = t.speakerTurns()
        #expect(turns.count == 2)
        #expect(turns[1].text == "B1 B2")
    }

    @Test func turnTimingSpansAllSegments() {
        let t = RichTranscript(version: 1, segments: [
            seg("w1", speaker: "A", start: 5, end: 10),
            seg("w2", speaker: "A", start: 10, end: 15),
            seg("w3", speaker: "A", start: 15, end: 20),
        ], speakerLabels: [])
        let turn = t.speakerTurns()[0]
        #expect(turn.startTime == 5)
        #expect(turn.endTime == 20)
    }
}
