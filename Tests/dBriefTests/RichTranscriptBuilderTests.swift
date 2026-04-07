import Foundation
@testable import dBrief
import Testing

struct RichTranscriptBuilderTests {
    @Test("segments with word timestamps produce populated tokens")
    func buildWithWordTimestamps() {
        let result = TranscriptionResult(
            text: "Hello world",
            segments: [
                TranscriptionResult.Segment(
                    start: 0.0,
                    end: 1.0,
                    text: "Hello world",
                    words: [
                        TranscriptionResult.Word(word: "Hello", start: 0.0, end: 0.5),
                        TranscriptionResult.Word(word: "world", start: 0.5, end: 1.0),
                    ]
                ),
            ]
        )

        let transcript = RichTranscriptBuilder().build(from: result)

        #expect(transcript.segments.count == 1)
        #expect(transcript.segments[0].tokens.count == 2)
        #expect(transcript.segments[0].tokens[0].text == "Hello")
        #expect(transcript.segments[0].tokens[0].start == 0.0)
        #expect(transcript.segments[0].tokens[0].end == 0.5)
        #expect(transcript.segments[0].tokens[0].isFillerWord == false)
        #expect(transcript.segments[0].tokens[1].text == "world")
    }

    @Test("segments without word timestamps produce empty tokens")
    func buildWithoutWordTimestamps() {
        let result = TranscriptionResult(
            text: "No words",
            segments: [
                TranscriptionResult.Segment(start: 0.0, end: 2.0, text: "No words"),
            ]
        )

        let transcript = RichTranscriptBuilder().build(from: result)

        #expect(transcript.segments.count == 1)
        #expect(transcript.segments[0].tokens.isEmpty)
    }

    @Test("originalText matches input text and isEdited defaults to false")
    func originalTextMatchesInput() {
        let result = TranscriptionResult(
            text: "Original text",
            segments: [
                TranscriptionResult.Segment(start: 0.0, end: 1.0, text: "Original text"),
            ]
        )

        let transcript = RichTranscriptBuilder().build(from: result)

        #expect(transcript.segments[0].text == "Original text")
        #expect(transcript.segments[0].originalText == "Original text")
        #expect(transcript.segments[0].isEdited == false)
    }

    @Test("isFillerWord defaults to false for all tokens")
    func fillerWordDefaultsFalse() {
        let result = TranscriptionResult(
            text: "Um well",
            segments: [
                TranscriptionResult.Segment(
                    start: 0.0,
                    end: 1.0,
                    text: "Um well",
                    words: [
                        TranscriptionResult.Word(word: "Um", start: 0.0, end: 0.3),
                        TranscriptionResult.Word(word: "well", start: 0.3, end: 1.0),
                    ]
                ),
            ]
        )

        let transcript = RichTranscriptBuilder().build(from: result)
        #expect(transcript.segments[0].tokens.allSatisfy { !$0.isFillerWord })
    }
}
