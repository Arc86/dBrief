import Foundation
import dBriefWire

/// A speaker identity resolved from the voice library, injected into the builder.
struct ResolvedSpeaker: Equatable {
    let name: String
    let personId: String?
}

struct RichTranscriptBuilder {
    /// Builds the rich transcript. `resolved` maps a diarization speaker id to a
    /// library-resolved identity (Phase 2); those win over the ordinal
    /// participant mapping, which in turn wins over the raw speaker id. A
    /// participant name already claimed by a resolved match is not reused.
    ///
    /// `suppressOrdinalGuess` disables the ordinal participant fallback for
    /// speakers the voice resolver did NOT match: instead of guessing a name by
    /// participant order (an arbitrary 50/50 for two speakers — the source of
    /// the "swapped labels" bug), an unmatched speaker keeps its raw "Speaker N"
    /// id. Set this when a voice library exists, so the only confident naming
    /// signal is voice matching; an embedding-extraction miss then shows a
    /// neutral "Speaker N" the user can rename, never a wrong name.
    func build(
        from result: TranscriptionResult,
        participants: [String] = [],
        resolved: [String: ResolvedSpeaker] = [:],
        suppressOrdinalGuess: Bool = false
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

        let uniqueSpeakerIds = Array(Set(segments.compactMap { $0.speakerId })).sorted()

        // Participants not already claimed by a resolved match, consumed by ordinal.
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let usedNames = Set(resolved.values.map { norm($0.name) })
        let participantQueue = participants.filter { !usedNames.contains(norm($0)) }
        var pIndex = 0

        let labels = uniqueSpeakerIds.map { id -> SpeakerLabel in
            if let r = resolved[id] {
                return SpeakerLabel(id: id, displayName: r.name, personId: r.personId)
            }
            if !suppressOrdinalGuess, pIndex < participantQueue.count {
                defer { pIndex += 1 }
                return SpeakerLabel(id: id, displayName: participantQueue[pIndex])
            }
            return SpeakerLabel(id: id, displayName: id)
        }

        return RichTranscript(segments: segments, speakerLabels: labels)
    }
}
