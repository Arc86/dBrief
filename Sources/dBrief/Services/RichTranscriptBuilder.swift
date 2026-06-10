import Foundation
import dBriefWire

struct RichTranscriptBuilder {
    /// - Parameters:
    ///   - participants: names mapped to speakers by ordinal (first appearance).
    ///   - recognizedNames: `speakerId -> name` from voiceprint recognition;
    ///     takes precedence over the ordinal participant fallback so a known
    ///     person keeps their name regardless of speaking order.
    func build(
        from result: TranscriptionResult,
        participants: [String] = [],
        recognizedNames: [String: String] = [:]
    ) -> RichTranscript {
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

        // Speaker labels resolve in priority order: recognized name → ordinal
        // participant name → raw speaker id. Ordinal fallback only consumes
        // participant slots for speakers that weren't recognized.
        let labels = Self.speakerLabels(
            for: segments.compactMap(\.speakerId),
            participants: participants,
            recognizedNames: recognizedNames
        )
        return RichTranscript(segments: segments, speakerLabels: labels)
    }

    /// Build speaker labels for the unique speaker ids in first-appearance order.
    static func speakerLabels(
        for speakerIds: [String],
        participants: [String],
        recognizedNames: [String: String]
    ) -> [SpeakerLabel] {
        var seen = Set<String>()
        let ordered = speakerIds.filter { seen.insert($0).inserted }
        var participantIndex = 0
        return ordered.map { id in
            if let name = recognizedNames[id] {
                return SpeakerLabel(id: id, displayName: name)
            }
            if participantIndex < participants.count {
                let name = participants[participantIndex]
                participantIndex += 1
                return SpeakerLabel(id: id, displayName: name)
            }
            return SpeakerLabel(id: id, displayName: id)
        }
    }
}
