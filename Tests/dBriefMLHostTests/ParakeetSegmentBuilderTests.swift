import Foundation
import FluidAudio
import Testing
@testable import dBriefMLHost

struct ParakeetSegmentBuilderTests {
    private func token(_ t: String, _ start: Double, _ end: Double, _ conf: Float = 1.0) -> TokenTiming {
        TokenTiming(token: t, tokenId: 0, startTime: start, endTime: end, confidence: conf)
    }

    @Test("SentencePiece tokens are grouped into words on the ▁ boundary")
    func buildsWordsFromTokens() {
        let timings = [
            token("▁Hello", 0.0, 0.4),
            token("▁wor", 0.5, 0.7),
            token("ld", 0.7, 0.9),
        ]
        let words = ParakeetTranscriptionService.buildWords(from: timings)
        #expect(words.count == 2)
        #expect(words[0].word == "Hello")
        #expect(words[0].start == 0.0)
        #expect(words[0].end == 0.4)
        #expect(words[1].word == "world")
        #expect(words[1].start == 0.5)
        #expect(words[1].end == 0.9)
    }

    @Test("a long pause between words starts a new segment")
    func splitsSegmentsOnPause() {
        let timings = [
            token("▁one", 0.0, 0.4),
            token("▁two", 0.5, 0.9),
            // 2s gap > 1s threshold -> new segment
            token("▁three", 3.0, 3.4),
        ]
        let segments = ParakeetTranscriptionService.buildSegments(
            from: timings, fullText: "one two three", duration: 3.4
        )
        #expect(segments.count == 2)
        #expect(segments[0].text == "one two")
        #expect(segments[1].text == "three")
        #expect(segments[0].words?.count == 2)
    }

    @Test("missing token timings fall back to a single full-file segment")
    func fallbackWhenNoTimings() {
        let segments = ParakeetTranscriptionService.buildSegments(
            from: nil, fullText: "whole file text", duration: 12.5
        )
        #expect(segments.count == 1)
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 12.5)
        #expect(segments[0].text == "whole file text")
        #expect(segments[0].words == nil)
    }
}
