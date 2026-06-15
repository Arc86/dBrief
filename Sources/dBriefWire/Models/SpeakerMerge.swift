import Foundation

/// Merges speaker turns from a standalone diarization pass onto a
/// `TranscriptionResult` by time overlap. Pure and synchronous so it can be
/// unit-tested and shared by any transcription engine (currently Parakeet,
/// which has no built-in speaker support).
///
/// When the transcript carries word-level timing, each word is attributed to
/// the diarized turn it overlaps with most and consecutive same-speaker words
/// are regrouped into speaker-labeled segments — mirroring the segment shape
/// WhisperKit + SpeakerKit produce. When word timing is absent (e.g. the
/// single full-file fallback segment), speakers are assigned per segment.
public enum SpeakerMerge {
    /// Returns a copy of `result` with `speaker` set on segments/words and
    /// `speakerCount` populated. Returns `result` unchanged when there are no
    /// turns to merge.
    public static func merge(_ result: TranscriptionResult, turns: [DiarizedTurn]) -> TranscriptionResult {
        guard !turns.isEmpty else { return result }

        let allWords = result.segments.flatMap { $0.words ?? [] }
        if allWords.isEmpty {
            return mergePerSegment(result, turns: turns)
        }
        return mergePerWord(result, words: allWords, turns: turns)
    }

    // MARK: - Word-level

    private static func mergePerWord(
        _ result: TranscriptionResult,
        words: [TranscriptionResult.Word],
        turns: [DiarizedTurn]
    ) -> TranscriptionResult {
        // Attribute each word to its best-overlapping turn.
        let labeled: [TranscriptionResult.Word] = words.map { w in
            var copy = w
            copy.speaker = bestSpeaker(start: w.start, end: w.end, turns: turns)
            return copy
        }

        // Regroup consecutive same-speaker words into segments.
        var segments: [TranscriptionResult.Segment] = []
        var bucket: [TranscriptionResult.Word] = []
        var currentSpeaker: String? = nil

        func flush() {
            guard let first = bucket.first, let last = bucket.last else { return }
            let text = bucket.map(\.word).joined(separator: " ")
            segments.append(
                TranscriptionResult.Segment(
                    start: first.start,
                    end: last.end,
                    text: text,
                    words: bucket,
                    speaker: currentSpeaker
                )
            )
            bucket = []
        }

        for w in labeled {
            if w.speaker != currentSpeaker, !bucket.isEmpty {
                flush()
            }
            currentSpeaker = w.speaker
            bucket.append(w)
        }
        flush()

        let speakerCount = Set(labeled.compactMap(\.speaker)).count
        return TranscriptionResult(
            text: result.text,
            segments: segments,
            language: result.language,
            warnings: result.warnings,
            speakerCount: speakerCount > 0 ? speakerCount : nil
        )
    }

    // MARK: - Segment-level fallback

    private static func mergePerSegment(
        _ result: TranscriptionResult,
        turns: [DiarizedTurn]
    ) -> TranscriptionResult {
        let segments = result.segments.map { seg -> TranscriptionResult.Segment in
            var copy = seg
            copy.speaker = bestSpeaker(start: seg.start, end: seg.end, turns: turns)
            return copy
        }
        let speakerCount = Set(segments.compactMap(\.speaker)).count
        return TranscriptionResult(
            text: result.text,
            segments: segments,
            language: result.language,
            warnings: result.warnings,
            speakerCount: speakerCount > 0 ? speakerCount : nil
        )
    }

    // MARK: - Segment-preserving merge

    /// Overlays speakers on `result` **purely additively** — every segment's
    /// text, timing, and word list are preserved verbatim; only `speaker`
    /// labels are attached (one per segment by best time overlap, plus per-word
    /// when word timing is present).
    ///
    /// This is the safe counterpart to `merge`, which rebuilds segments from a
    /// flattened word stream. Two ways `merge` loses text that this avoids:
    /// segments with no word timing vanish entirely, and segments whose words
    /// only partially cover their text get truncated to the timed words. A
    /// custom-vocabulary `initialPrompt` triggers exactly that in WhisperKit
    /// (partial / sparse word timestamps), and the old
    /// `SpeakerKit.addSpeakerInfo(strategy: .subsegment)` path dropped the bulk
    /// of the transcript as a result. Because this never rebuilds text from
    /// words, the full transcript always survives diarization. The trade-off is
    /// no within-segment speaker splitting — acceptable since WhisperKit's VAD
    /// segments are short, single-utterance spans.
    public static func mergePreservingSegments(
        _ result: TranscriptionResult,
        turns: [DiarizedTurn]
    ) -> TranscriptionResult {
        guard !turns.isEmpty else { return result }

        let outSegments = result.segments.map { seg -> TranscriptionResult.Segment in
            var copy = seg
            copy.speaker = bestSpeaker(start: seg.start, end: seg.end, turns: turns)
            if let words = seg.words {
                copy.words = words.map { w in
                    var wc = w
                    wc.speaker = bestSpeaker(start: w.start, end: w.end, turns: turns)
                    return wc
                }
            }
            return copy
        }

        // Count distinct speakers across segments and words (a single segment
        // can contain words from more than one speaker).
        var speakers = Set(outSegments.compactMap(\.speaker))
        for seg in outSegments { for w in seg.words ?? [] { if let s = w.speaker { speakers.insert(s) } } }
        return TranscriptionResult(
            text: result.text,
            segments: outSegments,
            language: result.language,
            warnings: result.warnings,
            speakerCount: speakers.isEmpty ? nil : speakers.count
        )
    }

    // MARK: - Overlap

    /// The id of the turn overlapping `[start, end]` most, or `nil` if none do.
    static func bestSpeaker(start: Double, end: Double, turns: [DiarizedTurn]) -> String? {
        var bestId: String? = nil
        var bestOverlap = 0.0
        for turn in turns {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestId = turn.speakerId
            }
        }
        return bestId
    }
}
