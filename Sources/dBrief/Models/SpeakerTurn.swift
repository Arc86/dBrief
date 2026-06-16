import Foundation

/// A merged run of consecutive `RichSegment`s from the same speaker.
/// Used for display only — the underlying segments are preserved for seeking,
/// editing, and persistence.
struct SpeakerTurn: Identifiable, Sendable {
    let id: UUID
    let speakerId: String?
    let segments: [RichSegment]

    init(speakerId: String?, segments: [RichSegment]) {
        // Derive a stable id from the first segment so repeated `speakerTurns()`
        // calls (and re-renders) yield consistent turn identity — required for
        // match-to-turn mapping, scroll-to, and the playback auto-scroll.
        self.id = segments.first?.id ?? UUID()
        self.speakerId = speakerId
        self.segments = segments
    }

    /// Playback start time (from first segment).
    var startTime: Double { segments.first?.start ?? 0 }

    /// Playback end time (from last segment).
    var endTime: Double { segments.last?.end ?? 0 }

    /// Full display text — segments joined with a single space.
    var text: String { segments.map(\.text).joined(separator: " ") }
}

extension RichTranscript {
    /// Returns segments merged into speaker turns.
    ///
    /// Consecutive segments that share the same non-nil `speakerId` are combined.
    /// Segments with `speakerId == nil` each become their own turn (no merging).
    func speakerTurns() -> [SpeakerTurn] {
        guard !segments.isEmpty else { return [] }

        var turns: [SpeakerTurn] = []
        var bucket: [RichSegment] = [segments[0]]

        for segment in segments.dropFirst() {
            let canMerge = segment.speakerId != nil
                && segment.speakerId == bucket.last?.speakerId
            if canMerge {
                bucket.append(segment)
            } else {
                turns.append(SpeakerTurn(speakerId: bucket[0].speakerId, segments: bucket))
                bucket = [segment]
            }
        }
        turns.append(SpeakerTurn(speakerId: bucket[0].speakerId, segments: bucket))
        return turns
    }
}
