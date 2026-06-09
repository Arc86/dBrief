import Foundation
import Testing
@testable import dBriefWire

@Suite("AppleSpeechResultMapper")
struct AppleSpeechResultMapperTests {
    @Test("Maps chunks to segments with word-level timestamps")
    func mapsWordsAndSegments() {
        let chunks = [
            AppleSpeechChunk(
                text: " Hello world",
                start: 0.0,
                end: 1.5,
                runs: [
                    AppleSpeechRun(text: " Hello", start: 0.0, end: 0.6),
                    AppleSpeechRun(text: " world", start: 0.7, end: 1.5),
                ]
            ),
            AppleSpeechChunk(
                text: " again",
                start: 1.6,
                end: 2.0,
                runs: [AppleSpeechRun(text: " again", start: 1.6, end: 2.0)]
            ),
        ]

        let result = AppleSpeechResultMapper.map(chunks, language: "en-US")

        #expect(result.text == "Hello world again")
        #expect(result.language == "en-US")
        #expect(result.segments.count == 2)

        let first = result.segments[0]
        #expect(first.text == "Hello world")
        #expect(first.start == 0.0)
        #expect(first.end == 1.5)
        #expect(first.words?.count == 2)
        #expect(first.words?[0].word == "Hello")
        #expect(first.words?[0].start == 0.0)
        #expect(first.words?[0].end == 0.6)
        #expect(first.words?[1].word == "world")
    }

    @Test("Drops empty/whitespace-only runs and chunks")
    func dropsEmptyEntries() {
        let chunks = [
            AppleSpeechChunk(
                text: "   ",
                start: 0.0,
                end: 0.2,
                runs: [AppleSpeechRun(text: "   ", start: 0.0, end: 0.2)]
            ),
            AppleSpeechChunk(
                text: "Hi",
                start: 0.3,
                end: 0.5,
                runs: [
                    AppleSpeechRun(text: "Hi", start: 0.3, end: 0.5),
                    AppleSpeechRun(text: "  ", start: 0.5, end: 0.6),
                ]
            ),
        ]

        let result = AppleSpeechResultMapper.map(chunks, language: nil)

        #expect(result.segments.count == 1)
        #expect(result.text == "Hi")
        #expect(result.segments[0].words?.count == 1)
        #expect(result.language == nil)
    }

    @Test("Empty language string normalizes to nil")
    func emptyLanguageBecomesNil() {
        let result = AppleSpeechResultMapper.map(
            [AppleSpeechChunk(text: "x", start: 0, end: 1, runs: [])],
            language: ""
        )
        #expect(result.language == nil)
        // A chunk with no runs still yields a segment, just without word timings.
        #expect(result.segments.count == 1)
        #expect(result.segments[0].words == nil)
    }
}
