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

    // MARK: - mergePreservingSegments

    @Test("preserving merge keeps text of segments that lack word timing (mixed case)")
    func preservingKeepsWordlessSegments() {
        // Reproduces the WhisperKit + custom-vocabulary-prompt bug: some segments
        // carry word timing, most don't. The old subsegment merge dropped every
        // word-less segment; mergePreservingSegments must keep all of them.
        let input = TranscriptionResult(
            text: "alpha beta gamma delta epsilon",
            segments: [
                TranscriptionResult.Segment(start: 0, end: 2, text: "alpha beta",
                                            words: [word("alpha", 0, 1), word("beta", 1, 2)]),
                TranscriptionResult.Segment(start: 2, end: 5, text: "gamma"),      // no words
                TranscriptionResult.Segment(start: 5, end: 8, text: "delta epsilon"), // no words
            ]
        )
        let turns = [DiarizedTurn(speakerId: "Speaker 1", start: 0, end: 8)]
        let out = SpeakerMerge.mergePreservingSegments(input, turns: turns)

        let joined = out.segments.map(\.text).joined(separator: " ")
        #expect(joined.contains("gamma"))
        #expect(joined.contains("delta epsilon"))
        #expect(out.segments.allSatisfy { $0.speaker == "Speaker 1" })
        #expect(out.text == "alpha beta gamma delta epsilon")
    }

    @Test("preserving merge keeps segment text verbatim and labels words")
    func preservingKeepsTextLabelsWords() {
        // A word-timed segment must NOT be rebuilt from words (that truncates
        // text when word timing is partial). Text/timing stay verbatim; the
        // segment gets its majority speaker and each word gets its own label.
        let input = TranscriptionResult(
            text: "a b c d",
            segments: [
                TranscriptionResult.Segment(start: 0, end: 4, text: "a b c d",
                                            words: [word("a", 0, 1), word("b", 1, 2), word("c", 2, 3), word("d", 3, 4)])
            ]
        )
        let turns = [
            DiarizedTurn(speakerId: "Speaker 1", start: 0, end: 2),
            DiarizedTurn(speakerId: "Speaker 2", start: 2, end: 4),
        ]
        let out = SpeakerMerge.mergePreservingSegments(input, turns: turns)
        #expect(out.segments.count == 1)
        #expect(out.segments[0].text == "a b c d")        // verbatim, not truncated
        #expect(out.segments[0].words?.map(\.speaker) == ["Speaker 1", "Speaker 1", "Speaker 2", "Speaker 2"])
        #expect(out.speakerCount == 2)
    }

    @Test("preserving merge keeps text when words only partially cover the segment")
    func preservingKeepsPartiallyTimedText() {
        // The custom-vocabulary-prompt case: a segment with rich text but only a
        // couple of timed words. Rebuilding from words would lose most of it.
        let input = TranscriptionResult(
            text: "tip seven if you are lazy like me",
            segments: [
                TranscriptionResult.Segment(start: 100, end: 110, text: "tip seven if you are lazy like me",
                                            words: [word("tip", 100, 100.5), word("seven", 100.5, 101)])
            ]
        )
        let turns = [DiarizedTurn(speakerId: "Speaker 1", start: 100, end: 110)]
        let out = SpeakerMerge.mergePreservingSegments(input, turns: turns)
        #expect(out.segments.count == 1)
        #expect(out.segments[0].text == "tip seven if you are lazy like me")
        #expect(out.segments[0].end == 110)
    }

    @Test("preserving merge with no turns returns the result unchanged")
    func preservingNoTurnsPassthrough() {
        let input = TranscriptionResult(
            text: "hello", segments: [TranscriptionResult.Segment(start: 0, end: 1, text: "hello")]
        )
        let out = SpeakerMerge.mergePreservingSegments(input, turns: [])
        #expect(out.segments.count == 1)
        #expect(out.segments[0].speaker == nil)
    }
}
