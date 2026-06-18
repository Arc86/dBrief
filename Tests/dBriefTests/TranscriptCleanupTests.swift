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

    @Test("Preserves speakerEmbeddings and diarizationTime through cleanup")
    func preservesEmbeddingsAndDiarizationTime() {
        let input = TranscriptionResult(
            text: "hello world",
            segments: [.init(start: 0, end: 1, text: "hello world", speaker: "Speaker 1")],
            diarizationTime: 2.5,
            speakerEmbeddings: ["Speaker 1": [0.1, 0.2, 0.3]]
        )
        let out = TranscriptCleanup.clean(input, removeFillerWords: false)
        #expect(out.speakerEmbeddings?["Speaker 1"] == [0.1, 0.2, 0.3])
        #expect(out.diarizationTime == 2.5)
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

    // MARK: - Ignored segments

    @Test("Strips asterisk-wrapped stage directions")
    func stripsAsteriskAnnotations() {
        let out = TranscriptCleanup.cleanText("Hello *music* there *laughs*", fillerWords: [])
        #expect(out == "Hello there")
    }

    @Test("Strips leading and trailing dash runs")
    func stripsBoundaryDashes() {
        #expect(TranscriptCleanup.cleanText("- Hello world", fillerWords: []) == "Hello world")
        #expect(TranscriptCleanup.cleanText("Hello world —", fillerWords: []) == "Hello world")
        #expect(TranscriptCleanup.cleanText("— Right —", fillerWords: []) == "Right")
    }

    @Test("Keeps mid-sentence hyphens")
    func keepsInnerHyphens() {
        let out = TranscriptCleanup.cleanText("A well-known follow-up", fillerWords: [])
        #expect(out == "A well-known follow-up")
    }

    @Test("normalizeForIgnoreMatch is case/punctuation/whitespace insensitive")
    func ignoreNormalization() {
        #expect(TranscriptCleanup.normalizeForIgnoreMatch("Thank you for watching!") == "thank you for watching")
        #expect(TranscriptCleanup.normalizeForIgnoreMatch("  THANKS   for  watching. ") == "thanks for watching")
    }

    @Test("clean() drops whole segments matching an ignored phrase")
    func dropsIgnoredSegments() {
        let result = TranscriptionResult(
            text: "Let's begin. Thank you for watching!",
            segments: [
                .init(start: 0, end: 2, text: "Let's begin."),
                .init(start: 2, end: 4, text: "Thank you for watching!"),
            ]
        )
        let ignored: Set<String> = ["thank you for watching"]
        let cleaned = TranscriptCleanup.clean(result, removeFillerWords: false, ignoredSegments: ignored)
        #expect(cleaned.segments.count == 1)
        #expect(cleaned.segments[0].text == "Let's begin.")
        #expect(cleaned.text == "Let's begin.")
    }

    @Test("clean() keeps real speech that merely contains an ignored phrase")
    func keepsPartialMatches() {
        let result = TranscriptionResult(
            text: "I wanted to thank you for watching the demo earlier.",
            segments: [.init(start: 0, end: 3, text: "I wanted to thank you for watching the demo earlier.")]
        )
        let cleaned = TranscriptCleanup.clean(result, removeFillerWords: false,
                                              ignoredSegments: ["thank you for watching"])
        #expect(cleaned.segments.count == 1)
    }

    @Test("clean() does nothing when ignore set is empty (back-compat)")
    func noIgnoreWhenEmpty() {
        let result = TranscriptionResult(
            text: "Thank you for watching",
            segments: [.init(start: 0, end: 1, text: "Thank you for watching")]
        )
        let cleaned = TranscriptCleanup.clean(result, removeFillerWords: false)
        #expect(cleaned.segments.count == 1)
        #expect(cleaned.text == "Thank you for watching")
    }

    @Test("Default ignore list catches a bracket-free music annotation after cleanup")
    func defaultListCatchesMusic() {
        let ignored = Set(TranscriptCleanup.defaultIgnoredSegments.map(TranscriptCleanup.normalizeForIgnoreMatch))
        // "[Music]" is bracket-stripped to empty (dropped as empty); a bare "Music." relies on the list.
        let result = TranscriptionResult(
            text: "Music.",
            segments: [.init(start: 0, end: 1, text: "Music.")]
        )
        let cleaned = TranscriptCleanup.clean(result, removeFillerWords: false, ignoredSegments: ignored)
        #expect(cleaned.segments.isEmpty)
    }
}
