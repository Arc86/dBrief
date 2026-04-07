import Foundation

struct RichTranscriptBuilder {
    func build(from result: TranscriptionResult) -> RichTranscript {
        RichTranscript(from: result)
    }

    func build(from result: TranscriptionResult, starring: Set<UUID> = []) -> RichTranscript {
        var transcript = RichTranscript(from: result)
        for idx in transcript.segments.indices {
            if starring.contains(transcript.segments[idx].id) {
                transcript.segments[idx].isStarred = true
            }
        }
        return transcript
    }
}
