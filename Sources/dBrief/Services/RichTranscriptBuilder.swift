import Foundation
import dBriefWire

struct RichTranscriptBuilder {
    func build(from result: TranscriptionResult, participants: [String] = []) -> RichTranscript {
        let segments = result.segments.map { seg -> RichSegment in
            let tokens: [RichToken] = seg.words?.map { word in
                RichToken(text: word.word, start: word.start, end: word.end)
            } ?? []
            return RichSegment(
                start: seg.start,
                end: seg.end,
                text: seg.text,
                originalText: seg.text,
                tokens: tokens,
                speakerId: seg.speaker
            )
        }

        // Build speaker labels, mapping participant names by ordinal when available
        let speakerIds = segments.compactMap { $0.speakerId }
        let uniqueSpeakerIds = Array(Set(speakerIds)).sorted()
        let labels = uniqueSpeakerIds.enumerated().map { index, id in
            let displayName = index < participants.count ? participants[index] : id
            return SpeakerLabel(id: id, displayName: displayName)
        }

        return RichTranscript(segments: segments, speakerLabels: labels)
    }
}
