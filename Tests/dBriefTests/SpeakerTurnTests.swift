import Foundation
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

    @Test func shortChunksReadAsOneParagraphWithoutChangingSegments() {
        let segments = [
            seg("Dat", speaker: "A", start: 0, end: 1),
            seg("zei je net.", speaker: "A", start: 1, end: 2),
            seg("Dat vond ik mooi.", speaker: "A", start: 2, end: 3),
        ]
        let turn = RichTranscript(segments: segments).speakerTurns()[0]
        #expect(turn.readingParagraphRanges == [0..<turn.text.count])
        #expect(turn.segments.map(\.id) == segments.map(\.id))
        #expect(turn.text == "Dat zei je net. Dat vond ik mooi.")
        #expect(turn.startTime == 0 && turn.endTime == 3)
        let search = TranscriptSearch.search(turns: [(id: turn.id, text: turn.text)], query: "Dat zei")
        #expect(search.matches.count == 1)
        #expect(search.matches.first?.turnId == turn.id)
        #expect(search.matches.first?.location == 0)
        #expect(search.matches.first?.length == 7)
    }

    @Test func meaningfulPauseStartsANewParagraphWithExactOffsets() {
        let turn = SpeakerTurn(speakerId: "A", segments: [
            seg("Café 👩🏽‍💻.", speaker: "A", start: 0, end: 1),
            seg("volgende zin", speaker: "A", start: 3, end: 4),
        ])
        let characters = Array(turn.text)
        let paragraphs = turn.readingParagraphRanges.map { String(characters[$0]) }
        #expect(paragraphs == ["Café 👩🏽‍💻.", "volgende zin"])
    }

    @Test func pauseMidSentenceKeepsTheParagraphTogether() {
        let turn = SpeakerTurn(speakerId: "A", segments: [
            seg("Ik heb het in die sessie ook", speaker: "A", start: 0, end: 2),
            seg("besproken, want het was nodig.", speaker: "A", start: 4, end: 6),
        ])
        #expect(turn.readingParagraphRanges == [0..<turn.text.count])
    }

    @Test func longSilenceBreaksEvenMidSentence() {
        let turn = SpeakerTurn(speakerId: "A", segments: [
            seg("en toen", speaker: "A", start: 0, end: 1),
            seg("na een lange stilte", speaker: "A", start: 8, end: 9),
        ])
        #expect(turn.readingParagraphRanges == [0..<7, 8..<turn.text.count])
    }

    @Test func longMonologuesKeepReadableParagraphBreaks() {
        let text = String(repeating: "word ", count: 75) + "end."
        let turn = SpeakerTurn(speakerId: "A", segments: [
            seg(text, speaker: "A", start: 0, end: 20),
            seg("Next sentence.", speaker: "A", start: 20, end: 22),
        ])
        #expect(turn.readingParagraphRanges == [0..<text.count, (text.count + 1)..<turn.text.count])
    }

    @Test func longParagraphWaitsForTheSentenceToEnd() {
        let text = String(repeating: "word ", count: 75) + "and"
        let turn = SpeakerTurn(speakerId: "A", segments: [
            seg(text, speaker: "A", start: 0, end: 20),
            seg("then it ends.", speaker: "A", start: 20, end: 22),
            seg("Next sentence.", speaker: "A", start: 22, end: 23),
        ])
        let firstEnd = text.count + 1 + "then it ends.".count
        #expect(turn.readingParagraphRanges == [0..<firstEnd, (firstEnd + 1)..<turn.text.count])
    }

    @Test func unpunctuatedMonologueStillBreaksAtTheHardCap() {
        let text = String(repeating: "word ", count: 150) // 750 characters
        let turn = SpeakerTurn(speakerId: "A", segments: [
            seg(text, speaker: "A", start: 0, end: 40),
            seg("more words", speaker: "A", start: 40, end: 41),
        ])
        #expect(turn.readingParagraphRanges == [0..<text.count, (text.count + 1)..<turn.text.count])
    }

    @Test func rebuildingAfterSegmentEditRefreshesCachedDisplayFields() {
        let first = seg("Short", speaker: "A", start: 0, end: 1)
        let second = seg("continuation", speaker: "A", start: 1, end: 2)
        let oldTurn = SpeakerTurn(speakerId: "A", segments: [first, second])

        var editedFirst = first
        editedFirst.text = String(repeating: "x", count: 359) + "."
        let updatedTurn = SpeakerTurn(speakerId: "A", segments: [editedFirst, second])

        #expect(updatedTurn.id == first.id)
        #expect(updatedTurn.segments.map(\.id) == [first.id, second.id])
        #expect(updatedTurn.text == "\(String(repeating: "x", count: 359)). continuation")
        #expect(updatedTurn.readingParagraphRanges == [0..<360, 361..<updatedTurn.text.count])

        #expect(oldTurn.id == first.id)
        #expect(oldTurn.text == "Short continuation")
        #expect(oldTurn.readingParagraphRanges == [0..<oldTurn.text.count])
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

    // MARK: - Stable identity (transcript search prerequisite)

    @Test("speakerTurns produces the same turn ids across repeated calls")
    func stableTurnIds() {
        let segments = [
            RichSegment(start: 0, end: 1, text: "Hello", originalText: "Hello", speakerId: "Speaker 1"),
            RichSegment(start: 1, end: 2, text: "there", originalText: "there", speakerId: "Speaker 1"),
            RichSegment(start: 2, end: 3, text: "Hi", originalText: "Hi", speakerId: "Speaker 2"),
        ]
        let transcript = RichTranscript(segments: segments)

        let first = transcript.speakerTurns()
        let second = transcript.speakerTurns()

        #expect(first.count == second.count)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("a turn's id matches its first segment's id")
    func idDerivedFromFirstSegment() {
        let seg = RichSegment(start: 0, end: 1, text: "Hello", originalText: "Hello")
        let transcript = RichTranscript(segments: [seg])

        let turns = transcript.speakerTurns()

        #expect(turns.first?.id == seg.id)
    }
}
