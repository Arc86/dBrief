import Foundation
import Testing
@testable import dBriefWire

@Suite("SpeechChunker")
struct SpeechChunkerTests {
    @Test func emptyReturnsNoChunks() {
        #expect(SpeechChunker.chunks("") == [])
        #expect(SpeechChunker.chunks("   \n  ") == [])
    }

    @Test func shortTextIsOneChunk() {
        #expect(SpeechChunker.chunks("Hello there. How are you?") == ["Hello there. How are you?"])
    }

    @Test func packsSentencesUpToLimitWithoutSplittingSentences() {
        let chunks = SpeechChunker.chunks(
            "One sentence here. Two sentence here. Three sentence here.",
            maxChars: 40
        )
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.count <= 40 })
        // No chunk splits a sentence — each ends on sentence punctuation.
        #expect(chunks.allSatisfy { $0.hasSuffix(".") })
    }

    @Test func hardSplitsOverlongPunctuationlessSentence() {
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        let chunks = SpeechChunker.chunks(long, maxChars: 50)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 50 })
    }

    @Test func preservesWordsAcrossChunks() {
        let input = "First sentence one. Second sentence two. Third sentence three."
        let rejoined = SpeechChunker.chunks(input, maxChars: 30).joined(separator: " ")
        #expect(rejoined == input)
    }
}
