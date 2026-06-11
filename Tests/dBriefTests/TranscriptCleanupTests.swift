import Foundation
import Testing
@testable import dBriefWire

@Suite("TranscriptCleanup")
struct TranscriptCleanupTests {

    @Test("Strips XML-ish tags and their content")
    func stripsTags() {
        let out = TranscriptCleanup.cleanText("Hello <i>there</i> <silence> world", fillerWords: [])
        #expect(out == "Hello world")
    }

    @Test("Strips square and brace bracket annotations but keeps parentheses")
    func stripsBracketAnnotations() {
        let out = TranscriptCleanup.cleanText("Welcome [BLANK_AUDIO] back {music} now (really)", fillerWords: [])
        #expect(out == "Welcome back now (really)")
    }

    @Test("Collapses whitespace and fixes space before punctuation")
    func normalizesWhitespace() {
        let out = TranscriptCleanup.cleanText("Hello    world [x] .", fillerWords: [])
        #expect(out == "Hello world.")
    }

    @Test("Leaves filler words when removal is disabled")
    func keepsFillersWhenDisabled() {
        let out = TranscriptCleanup.cleanText("So um I think uh yes", fillerWords: [])
        #expect(out == "So um I think uh yes")
    }

    @Test("Removes filler words when enabled, case-insensitively")
    func removesFillers() {
        let fillers = Set(TranscriptCleanup.defaultFillerWords)
        let out = TranscriptCleanup.cleanText("So, um, I think Um yes uh.", fillerWords: fillers)
        #expect(out == "So, I think yes.")
    }

    @Test("Removes multi-word fillers")
    func removesMultiWordFillers() {
        let fillers = Set(TranscriptCleanup.defaultFillerWords)
        let out = TranscriptCleanup.cleanText("It is, you know, fine", fillerWords: fillers)
        #expect(out == "It is, fine")
    }

    @Test("Does not remove filler substrings inside real words")
    func preservesRealWords() {
        let fillers = Set(TranscriptCleanup.defaultFillerWords)
        // "umbrella" contains "um", "number" contains "er" — must survive.
        let out = TranscriptCleanup.cleanText("The umbrella number", fillerWords: fillers)
        #expect(out == "The umbrella number")
    }

    @Test("clean() filters filler tokens from segment word arrays when enabled")
    func cleanFiltersWordArrays() {
        let result = TranscriptionResult(
            text: "um hello world",
            segments: [
                .init(
                    start: 0, end: 2, text: "um hello world",
                    words: [
                        .init(word: "um", start: 0, end: 0.2),
                        .init(word: "hello", start: 0.3, end: 0.7),
                        .init(word: "world", start: 0.8, end: 1.2),
                    ]
                )
            ]
        )
        let cleaned = TranscriptCleanup.clean(result, removeFillerWords: true)
        #expect(cleaned.text == "hello world")
        #expect(cleaned.segments[0].text == "hello world")
        #expect(cleaned.segments[0].words?.map(\.word) == ["hello", "world"])
    }

    @Test("clean() preserves word arrays when filler removal is off")
    func cleanKeepsWordArraysWhenOff() {
        let result = TranscriptionResult(
            text: "um hello",
            segments: [.init(start: 0, end: 1, text: "um hello",
                             words: [.init(word: "um", start: 0, end: 0.2),
                                     .init(word: "hello", start: 0.3, end: 0.7)])]
        )
        let cleaned = TranscriptCleanup.clean(result, removeFillerWords: false)
        #expect(cleaned.segments[0].words?.count == 2)
    }
}
