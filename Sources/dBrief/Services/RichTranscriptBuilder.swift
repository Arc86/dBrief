import Foundation

struct RichTranscriptBuilder {
    func build(from result: TranscriptionResult) -> RichTranscript {
        let segments = result.segments.map { seg -> RichSegment in
            let tokens: [RichToken] = seg.words?.map { word in
                RichToken(text: word.word, start: word.start, end: word.end)
            } ?? []
            return RichSegment(
                start: seg.start,
                end: seg.end,
                text: seg.text,
                originalText: seg.text,
                tokens: tokens
            )
        }
        return RichTranscript(segments: segments)
    }
}
