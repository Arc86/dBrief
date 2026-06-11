import Foundation

/// Engine-agnostic post-transcription text cleanup.
///
/// Runs on every transcription result regardless of engine. The always-on pass strips
/// hallucination/markup noise that Whisper-family models occasionally emit (XML-ish tags,
/// square/brace non-speech annotations like `[BLANK_AUDIO]` or `{music}`) and normalizes
/// whitespace. Filler-word removal (um, uh, …) is opt-in and off by default — meeting
/// records often want a verbatim transcript.
///
/// Inspired by VoiceInk's `TranscriptionOutputFilter`, but conservative: it does **not**
/// remove parenthesized `(…)` content, which in meetings is frequently real speech.
public enum TranscriptCleanup {

    /// Default filler tokens removed when filler removal is enabled. Lower-cased.
    /// Kept deliberately conservative — ambiguous words like "like" or "ah" are excluded
    /// because they're usually meaningful in real conversation.
    public static let defaultFillerWords: [String] = [
        "um", "umm", "ummm", "uh", "uhh", "uhm", "er", "err", "erm", "hmm", "hm",
        "you know", "i mean", "sort of", "kind of",
    ]

    /// Clean a full transcription result. Returns a new value; the input is unchanged.
    /// - Parameters:
    ///   - result: the raw engine output.
    ///   - removeFillerWords: when true, also strips `defaultFillerWords` from text and
    ///     drops matching single-token entries from each segment's `words` array.
    public static func clean(_ result: TranscriptionResult, removeFillerWords: Bool) -> TranscriptionResult {
        let fillers = removeFillerWords ? Set(defaultFillerWords) : []

        let newSegments = result.segments.map { seg -> TranscriptionResult.Segment in
            let cleanedText = cleanText(seg.text, fillerWords: fillers)
            let newWords: [TranscriptionResult.Word]?
            if let words = seg.words, removeFillerWords {
                newWords = words.filter { !isFillerToken($0.word, fillers) }
            } else {
                newWords = seg.words
            }
            return TranscriptionResult.Segment(
                start: seg.start,
                end: seg.end,
                text: cleanedText,
                words: newWords,
                speaker: seg.speaker
            )
        }

        let newText = cleanText(result.text, fillerWords: fillers)

        return TranscriptionResult(
            text: newText,
            segments: newSegments,
            language: result.language,
            warnings: result.warnings,
            speakerCount: result.speakerCount,
            inferenceTime: result.inferenceTime
        )
    }

    /// Clean a single string. Exposed for unit tests and reuse.
    public static func cleanText(_ text: String, fillerWords: Set<String>) -> String {
        var s = text

        // Paired XML-ish tags, e.g. "<i>foo</i>" → drop content too (dotall).
        s = s.regexReplace(#"<([A-Za-z][\w-]*)\b[^>]*>[\s\S]*?</\1>"#, with: " ")
        // Standalone / unbalanced tags, e.g. "<silence>" or "</p>".
        s = s.regexReplace(#"</?[A-Za-z][\w-]*\b[^>]*>"#, with: " ")
        // Whisper-style non-speech annotations in square/brace brackets.
        s = s.regexReplace(#"\[[^\]]*\]"#, with: " ")
        s = s.regexReplace(#"\{[^}]*\}"#, with: " ")

        if !fillerWords.isEmpty {
            let alternation = fillerWords
                .sorted { $0.count > $1.count } // longest first so multi-word phrases win
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            // Unicode-aware boundaries; eat an immediately trailing comma so "um," doesn't
            // leave a dangling comma. Leave sentence-ending periods intact (the
            // space-before-punctuation pass below reattaches them).
            s = s.regexReplace("(?i)(?<![\\p{L}\\p{N}])(?:\(alternation))(?![\\p{L}\\p{N}]),?", with: " ")
        }

        // Normalize whitespace and any space left in front of punctuation by removals.
        s = s.regexReplace(#"[ \t]{2,}"#, with: " ")
        s = s.regexReplace(#"\s+([,.!?;:])"#, with: "$1")
        s = s.regexReplace(#" *\n *"#, with: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isFillerToken(_ word: String, _ fillers: Set<String>) -> Bool {
        let normalized = word
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return !normalized.isEmpty && fillers.contains(normalized)
    }
}

private extension String {
    func regexReplace(_ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let range = NSRange(startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: template)
    }
}
