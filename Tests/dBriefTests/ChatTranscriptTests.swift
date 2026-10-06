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
}
