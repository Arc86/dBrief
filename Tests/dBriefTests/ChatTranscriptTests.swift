import Testing
import dBriefWire

@Suite struct ChatTranscriptTests {
    @Test func mergesConsecutiveSameSpeakerSegments() {
        let turns = ChatTranscript.turns([
            (0, 2, "Alice", "Hi."), (2, 4, "Alice", "Let's start."), (4, 6, "Bob", "Sure."),
        ])
        #expect(turns == [
            TranscriptTurn(start: 0, end: 4, speaker: "Alice", text: "Hi. Let's start."),
            TranscriptTurn(start: 4, end: 6, speaker: "Bob", text: "Sure."),
        ])
    }

    @Test func formatsTimestampAndName() {
        let text = ChatTranscript.format([
            TranscriptTurn(start: 3725, end: 3730, speaker: "Alice", text: "Budget is approved."),
            TranscriptTurn(start: 3731, end: 3732, speaker: nil, text: "Unlabelled."),
        ])
        #expect(text == "[01:02:05] Alice: Budget is approved.\n[01:02:11] Unlabelled.")
    }

    @Test func skipsBlankSegments() {
        #expect(ChatTranscript.turns([(0, 1, "A", "  "), (1, 2, "A", "x")]).map(\.text) == ["x"])
    }

    @Test func speakerNamesMapsLabelsWithEmptyFallback() {
        let names = ChatTranscript.speakerNames([
            (id: "a1", displayName: "Alice"),
            (id: "b1", displayName: ""),
            (id: "c1", displayName: "  "),
        ])
        #expect(names == ["a1": "Alice", "b1": "b1", "c1": "c1"])
    }

    @Test func speakerNamesPrefersDuplicateFirst() {
        let names = ChatTranscript.speakerNames([
            (id: "speaker1", displayName: "Alice"),
            (id: "speaker1", displayName: "Bob"),
        ])
        #expect(names == ["speaker1": "Alice"])
    }

    @Test func speakerNamesTrimsWhitespace() {
        let names = ChatTranscript.speakerNames([
            (id: "id1", displayName: "  Alice  "),
        ])
        #expect(names == ["id1": "Alice"])
    }

    @Test func turnsRespects60SecondLimit() {
        let turns = ChatTranscript.turns([
            (0, 30, "Alice", "Part 1."),
            (30, 50, "Alice", "Part 2."),
            (50, 80, "Alice", "Part 3."),
        ])
        #expect(turns.count == 2)
        #expect(turns[0].start == 0 && turns[0].end == 50 && turns[0].text == "Part 1. Part 2.")
        #expect(turns[1].start == 50 && turns[1].end == 80 && turns[1].text == "Part 3.")
    }

    @Test func nilSpeakerSegmentsSpanning200SecondsProduceMultipleTurns() {
        let turns = ChatTranscript.turns([
            (0, 40, nil, "A."),
            (40, 80, nil, "B."),
            (80, 120, nil, "C."),
            (120, 200, nil, "D."),
            (200, 240, nil, "E."),
        ])
        #expect(turns.count >= 4)
    }

    @Test func timestampHandlesNaN() {
        #expect(ChatTranscript.timestamp(.nan) == "00:00:00")
    }

    @Test func timestampHandlesInfinity() {
        #expect(ChatTranscript.timestamp(.infinity) == "00:00:00")
    }
}
