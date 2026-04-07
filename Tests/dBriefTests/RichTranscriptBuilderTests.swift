import Foundation
@testable import dBrief
import Testing

struct RichTranscriptBuilderTests {
    @Test("build creates RichTranscript from TranscriptionResult")
    func buildBasic() {
        let builder = RichTranscriptBuilder()
        let result = TranscriptionResult(
            text: "Hello world. Goodbye world.",
            segments: [
                TranscriptionResult.Segment(start: 0.0, end: 1.5, text: "Hello world."),
                TranscriptionResult.Segment(start: 1.5, end: 3.0, text: "Goodbye world."),
            ]
        )

        let transcript = builder.build(from: result)

        #expect(transcript.segments.count == 2)
        #expect(transcript.segments[0].text == "Hello world.")
        #expect(transcript.segments[0].start == 0.0)
        #expect(transcript.segments[0].end == 1.5)
        #expect(transcript.segments[0].isStarred == false)
        #expect(transcript.segments[0].editedText == nil)
        #expect(transcript.segments[1].text == "Goodbye world.")
        #expect(transcript.segments[1].isStarred == false)
    }

    @Test("build preserves word timings")
    func buildWithWordTimings() {
        let builder = RichTranscriptBuilder()
        let result = TranscriptionResult(
            text: "Hello world",
            segments: [
                TranscriptionResult.Segment(
                    start: 0.0,
                    end: 1.0,
                    text: "Hello world",
                    words: [
                        TranscriptionResult.Word(word: "Hello", start: 0.0, end: 0.5, probability: 0.99),
                        TranscriptionResult.Word(word: "world", start: 0.5, end: 1.0, probability: 0.98),
                    ]
                ),
            ]
        )

        let transcript = builder.build(from: result)

        #expect(transcript.segments.count == 1)
        #expect(transcript.segments[0].wordTimings?.count == 2)
        #expect(transcript.segments[0].wordTimings?[0].word == "Hello")
        #expect(transcript.segments[0].wordTimings?[0].start == 0.0)
        #expect(transcript.segments[0].wordTimings?[0].end == 0.5)
        #expect(transcript.segments[0].wordTimings?[0].probability == 0.99)
        #expect(transcript.segments[0].wordTimings?[1].word == "world")
        #expect(transcript.segments[0].wordTimings?[1].probability == 0.98)
    }

    @Test("build with starring marks correct segments")
    func buildWithStarring() {
        let builder = RichTranscriptBuilder()
        let result = TranscriptionResult(
            text: "First Second Third",
            segments: [
                TranscriptionResult.Segment(start: 0.0, end: 1.0, text: "First"),
                TranscriptionResult.Segment(start: 1.0, end: 2.0, text: "Second"),
                TranscriptionResult.Segment(start: 2.0, end: 3.0, text: "Third"),
            ]
        )

        let transcript = builder.build(from: result)
        #expect(transcript.segments[0].isStarred == false)
        #expect(transcript.segments[1].isStarred == false)
        #expect(transcript.segments[2].isStarred == false)

        let starring: Set<UUID> = [transcript.segments[1].id]
        let starredTranscript = builder.build(from: result, starring: starring)

        #expect(starredTranscript.segments[0].isStarred == false)
        #expect(starredTranscript.segments[1].isStarred == true)
        #expect(starredTranscript.segments[2].isStarred == false)
    }

    @Test("RichTranscript Segment displayText uses editedText when present")
    func displayTextPrefersEdited() {
        var segment = RichTranscript.Segment(
            start: 0.0,
            end: 1.0,
            text: "Original",
            isStarred: false,
            editedText: "Edited"
        )

        #expect(segment.displayText == "Edited")

        segment.editedText = nil
        #expect(segment.displayText == "Original")
    }
}
