import Foundation
import dBriefWire
import Testing

struct SpeakerMergeTests {
    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptionResult.Word {
        TranscriptionResult.Word(word: text, start: start, end: end)
    }

    @Test("no turns returns the result unchanged")
    func emptyTurnsPassthrough() {
        let input = TranscriptionResult(
            text: "hello world",
            segments: [
                TranscriptionResult.Segment(
                    start: 0, end: 2, text: "hello world",
                    words: [word("hello", 0, 1), word("world", 1, 2)]
                )
            ]
        )
        let out = SpeakerMerge.merge(input, turns: [])
        #expect(out.speakerCount == nil)
        #expect(out.segments.allSatisfy { $0.speaker == nil })
    }

    @Test("single speaker covering whole transcript labels everything")
    func singleSpeaker() {
        let input = TranscriptionResult(
            text: "hello world",
            segments: [
                TranscriptionResult.Segment(
                    start: 0, end: 2, text: "hello world",
                    words: [word("hello", 0, 1), word("world", 1, 2)]
                )
            ]
        )
        let turns = [DiarizedTurn(speakerId: "Speaker 1", start: 0, end: 2)]
        let out = SpeakerMerge.merge(input, turns: turns)
        #expect(out.speakerCount == 1)
        #expect(out.segments.count == 1)
        #expect(out.segments[0].speaker == "Speaker 1")
        #expect(out.segments[0].words?.allSatisfy { $0.speaker == "Speaker 1" } == true)
    }

    @Test("two speakers split at the word boundary into separate segments")
    func twoSpeakerSplit() {
        // One source segment spanning both speakers; expect it regrouped into two.
        let input = TranscriptionResult(
            text: "a b c d",
            segments: [
                TranscriptionResult.Segment(
                    start: 0, end: 4, text: "a b c d",
                    words: [word("a", 0, 1), word("b", 1, 2), word("c", 2, 3), word("d", 3, 4)]
                )
            ]
        )
        let turns = [
            DiarizedTurn(speakerId: "Speaker 1", start: 0, end: 2),
            DiarizedTurn(speakerId: "Speaker 2", start: 2, end: 4),
        ]
        let out = SpeakerMerge.merge(input, turns: turns)
        #expect(out.speakerCount == 2)
        #expect(out.segments.count == 2)
        #expect(out.segments[0].speaker == "Speaker 1")
        #expect(out.segments[0].text == "a b")
        #expect(out.segments[1].speaker == "Speaker 2")
        #expect(out.segments[1].text == "c d")
    }

    @Test("consecutive same-speaker words across input segments are merged")
    func regroupAcrossSegments() {
        let input = TranscriptionResult(
            text: "a b c d",
            segments: [
                TranscriptionResult.Segment(start: 0, end: 2, text: "a b",
                                            words: [word("a", 0, 1), word("b", 1, 2)]),
                TranscriptionResult.Segment(start: 2, end: 4, text: "c d",
                                            words: [word("c", 2, 3), word("d", 3, 4)]),
            ]
        )
        let turns = [DiarizedTurn(speakerId: "Speaker 1", start: 0, end: 4)]
        let out = SpeakerMerge.merge(input, turns: turns)
        #expect(out.segments.count == 1)
        #expect(out.segments[0].text == "a b c d")
        #expect(out.speakerCount == 1)
    }

    @Test("segment-level fallback when no word timing is present")
    func segmentLevelFallback() {
        let input = TranscriptionResult(
            text: "whole file",
            segments: [TranscriptionResult.Segment(start: 0, end: 10, text: "whole file")]
        )
        let turns = [
            DiarizedTurn(speakerId: "Speaker 1", start: 0, end: 3),
            DiarizedTurn(speakerId: "Speaker 2", start: 3, end: 10),
        ]
        let out = SpeakerMerge.merge(input, turns: turns)
        // One segment, attributed to the most-overlapping turn (Speaker 2).
        #expect(out.segments.count == 1)
        #expect(out.segments[0].speaker == "Speaker 2")
        #expect(out.speakerCount == 1)
    }
}
