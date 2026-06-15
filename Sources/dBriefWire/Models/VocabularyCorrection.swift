import Foundation

/// One spelling correction proposed by the LLM: replace `from` (text as it
/// appears in the transcript) with `to` (a canonical vocabulary term).
public struct SpellingCorrection: Sendable, Codable, Equatable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Applies LLM-proposed spelling corrections to a transcript **deterministically
/// and safely**. The LLM only *proposes* `{from, to}` pairs; this code decides
/// what actually changes:
///
/// - A correction is kept only when `to` is one of the user's vocabulary terms
///   (case-insensitive). The model can't substitute arbitrary text — only the
///   user's own domain terms can be written in.
/// - Each `from` is replaced as a whole-word, case-insensitive match across the
///   full text, every segment's text, and every word token. Everything else is
///   left byte-for-byte unchanged, so the model can never drop, reorder, or
///   reformat transcript content (the failure mode that makes "send the whole
///   transcript to an LLM and trust the rewrite" risky).
public enum VocabularyCorrection {
    public static func apply(
        _ corrections: [SpellingCorrection],
        vocabulary: [String],
        to result: TranscriptionResult
    ) -> TranscriptionResult {
        let vocabSet = Set(
            vocabulary
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !vocabSet.isEmpty else { return result }

        // Keep only safe corrections: `to` must be a real vocabulary term, `from`
        // non-empty, and an actual change. De-duplicate, longest `from` first so a
        // shorter term can't pre-empt a longer overlapping one.
        var seen = Set<String>()
        let valid: [(from: String, to: String)] = corrections.compactMap { c in
            let from = c.from.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = c.to.trimmingCharacters(in: .whitespacesAndNewlines)
            // Reject only an exact no-op; a case-only change (e.g. "kubernetes"
            // → "Kubernetes") is a real, common correction we want to keep.
            guard !from.isEmpty, !to.isEmpty, from != to,
                  vocabSet.contains(to.lowercased()),
                  seen.insert(from.lowercased()).inserted
            else { return nil }
            return (from, to)
        }
        .sorted { $0.from.count > $1.from.count }
        guard !valid.isEmpty else { return result }

        func fix(_ text: String) -> String {
            var out = text
            for c in valid { out = replaceWholeWord(in: out, from: c.from, to: c.to) }
            return out
        }

        let segments = result.segments.map { seg -> TranscriptionResult.Segment in
            let words = seg.words?.map { w in
                TranscriptionResult.Word(
                    word: fix(w.word),
                    start: w.start,
                    end: w.end,
                    probability: w.probability,
                    speaker: w.speaker
                )
            }
            return TranscriptionResult.Segment(
                start: seg.start,
                end: seg.end,
                text: fix(seg.text),
                words: words,
                speaker: seg.speaker
            )
        }

        return TranscriptionResult(
            text: fix(result.text),
            segments: segments,
            language: result.language,
            warnings: result.warnings,
            speakerCount: result.speakerCount,
            inferenceTime: result.inferenceTime
        )
    }

    /// Case-insensitive whole-word replacement of `from` with `to`. `to` is
    /// inserted verbatim (canonical casing); surrounding text is untouched.
    private static func replaceWholeWord(in text: String, from: String, to: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: from)
        let pattern = "\\b\(escaped)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: to)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
