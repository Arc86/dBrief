import Foundation

/// A merged run of consecutive `RichSegment`s from the same speaker.
/// Used for display only — the underlying segments are preserved for seeking,
/// editing, and persistence.
struct SpeakerTurn: Identifiable, Sendable, Equatable {
    let id: UUID
    let speakerId: String?
    let segments: [RichSegment]
    let text: String
    let readingParagraphRanges: [Range<Int>]

    init(speakerId: String?, segments: [RichSegment]) {
        // Derive a stable id from the first segment so repeated `speakerTurns()`
        // calls (and re-renders) yield consistent turn identity — required for
        // match-to-turn mapping, scroll-to, and the playback auto-scroll.
        self.id = segments.first?.id ?? UUID()
        self.speakerId = speakerId
        self.segments = segments
        self.text = segments.map(\.text).joined(separator: " ")
        self.readingParagraphRanges = Self.paragraphRanges(for: segments)
    }

    /// Playback start time (from first segment).
    var startTime: Double { segments.first?.start ?? 0 }

    /// Playback end time (from last segment).
    var endTime: Double { segments.last?.end ?? 0 }

    /// Display ranges coalesce short transcription chunks without changing their
    /// text offsets, identities, timing, or speaker assignments. Long monologues
    /// still break at segment boundaries: after a sentence once the paragraph is
    /// long or the speaker paused, and anywhere after a long silence or at a hard
    /// cap for unpunctuated text, so a breath mid-sentence never splits it.
    private static func paragraphRanges(for segments: [RichSegment]) -> [Range<Int>] {
        guard let first = segments.first else { return [] }
        var ranges: [Range<Int>] = []
        var paragraphStart = 0
        var end = first.text.count
        var previous = first
        for segment in segments.dropFirst() {
            let start = end + 1 // The space inserted by `text`.
            let pause = segment.start - previous.end
            let endsSentence = previous.text.trimmingCharacters(in: .whitespaces).last
                .map { ".?!…".contains($0) } ?? false
            let length = end - paragraphStart
            if ((length >= 360 || pause >= 2) && endsSentence) || pause >= 6 || length >= 720 {
                ranges.append(paragraphStart..<end)
                paragraphStart = start
            }
            end = start + segment.text.count
            previous = segment
        }
        ranges.append(paragraphStart..<end)
        return ranges
    }
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
