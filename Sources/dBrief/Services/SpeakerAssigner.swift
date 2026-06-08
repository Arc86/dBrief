import Foundation

/// Assigns speaker IDs from a standalone diarization pass onto an existing
/// transcript by time overlap. Each segment is attributed to the diarized turn
/// it overlaps with most. Pure and synchronous so it's easy to test.
enum SpeakerAssigner {
    /// Returns a copy of `transcript` with each segment's `speakerId` set to the
    /// best-overlapping diarized turn. Existing speaker labels are cleared, since
    /// a fresh diarization re-clusters speakers and old names may no longer match.
    static func assign(_ turns: [DiarizedTurn], to transcript: RichTranscript) -> RichTranscript {
        guard !turns.isEmpty else { return transcript }

        var updated = transcript
        for i in updated.segments.indices {
            let seg = updated.segments[i]
            var bestId: String? = nil
            var bestOverlap = 0.0
            for turn in turns {
                let overlap = min(seg.end, turn.end) - max(seg.start, turn.start)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestId = turn.speakerId
                }
            }
            if let bestId { updated.segments[i].speakerId = bestId }
        }
        updated.speakerLabels = []
        return updated
    }
}
