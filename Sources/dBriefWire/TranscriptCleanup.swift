import Foundation

/// Engine-agnostic post-transcription text cleanup.
///
/// Runs on every transcription result regardless of engine. The always-on pass strips
/// hallucination/markup noise that Whisper-family models occasionally emit (XML-ish tags,
/// square/brace non-speech annotations like `[BLANK_AUDIO]` or `{music}`) and normalizes
/// whitespace. Filler-word removal (um, uh, …) is opt-in and off by default — meeting
/// records often want a verbatim transcript.
///
/// Conservative by design: it does **not** remove parenthesized `(…)` content, which in
/// meetings is frequently real speech.
public enum TranscriptCleanup {

    /// Default filler tokens removed when filler removal is enabled. Lower-cased.
    /// Kept deliberately conservative — ambiguous words like "like" or "ah" are excluded
    /// because they're usually meaningful in real conversation.
    public static let defaultFillerWords: [String] = [
        "um", "umm", "ummm", "uh", "uhh", "uhm", "er", "err", "erm", "hmm", "hm",
        "you know", "i mean", "sort of", "kind of",
    ]

    /// Built-in phrases dropped when ignored-segment filtering is enabled. A segment is
    /// removed only when its **entire** cleaned text (after stripping punctuation/case)
    /// matches one of these — so real speech that merely contains a phrase is never touched.
    ///
    /// Curated for meeting safety: these are Whisper/YouTube silence-hallucinations and
    /// non-speech annotations that essentially never appear as a standalone utterance in a
    /// real meeting. Deliberately excludes ambiguous bare words ("okay", "you", "bye",
    /// "thank you", "the end") that are common, legitimate meeting speech. Lower-cased.
    public static let defaultIgnoredSegments: [String] = [
        // YouTube-style sign-offs
        "thank you for watching", "thanks for watching", "thank you for watching this video",
        "thanks for watching this video", "thank you so much for watching",
        "thank you all for watching", "thanks for watching the video",
        "see you in the next video", "see you in the next one", "see you next time",
        "i'll see you in the next video", "i'll see you next time", "see you guys next time",
        // Subscribe spam
        "please subscribe", "don't forget to subscribe", "subscribe to my channel",
        "please subscribe to my channel", "subscribe to the channel", "like and subscribe",
        "please like and subscribe", "don't forget to like and subscribe",
        "like, comment and subscribe", "like comment and subscribe",
        // Listening sign-offs
        "thanks for listening", "thank you for listening", "thanks for joining",
        // Subtitle/transcription credits
        "subtitles by", "subtitles by the amara.org community", "transcription by",
        "transcription by castingwords", "captions by", "subtitles by steamteamextra",
        "translated by", "edited by",
        // Promo
        "for more information visit our website", "for more information, visit our website",
        "for more information visit",
        // Non-speech annotations Whisper sometimes emits without brackets
        "music", "music playing", "upbeat music", "soft music", "dramatic music",
        "applause", "laughter", "silence", "no audio", "blank_audio",
        // Bare music-note runs
        "♪", "♪♪", "♪♪♪",
    ]

    /// Clean a full transcription result. Returns a new value; the input is unchanged.
    /// - Parameters:
    ///   - result: the raw engine output.
    ///   - removeFillerWords: when true, also strips `defaultFillerWords` from text and
    ///     drops matching single-token entries from each segment's `words` array.
    ///   - ignoredSegments: phrases (any case) whose exact whole-segment match causes that
    ///     segment to be dropped entirely. Empty disables the pass. The full-transcript
    ///     `text` is rebuilt from the surviving segments when any segment is dropped, so the
    ///     phrase disappears from both the timestamped and the flat transcript.
    public static func clean(
        _ result: TranscriptionResult,
        removeFillerWords: Bool,
        ignoredSegments: Set<String> = []
    ) -> TranscriptionResult {
        let fillers = removeFillerWords ? Set(defaultFillerWords) : []
        let ignored = Set(ignoredSegments.map(normalizeForIgnoreMatch))

        var newSegments: [TranscriptionResult.Segment] = []
        for seg in result.segments {
            let cleanedText = cleanText(seg.text, fillerWords: fillers)
            if isIgnoredSegment(cleanedText, ignored) { continue }
            let newWords: [TranscriptionResult.Word]?
            if let words = seg.words, removeFillerWords {
                newWords = words.filter { !isFillerToken($0.word, fillers) }
            } else {
                newWords = seg.words
            }
            newSegments.append(TranscriptionResult.Segment(
                start: seg.start,
                end: seg.end,
                text: cleanedText,
                words: newWords,
                speaker: seg.speaker
            ))
        }

        let droppedAnySegment = newSegments.count != result.segments.count
        let newText: String
        if droppedAnySegment && !newSegments.isEmpty {
            // Rebuild from survivors so dropped phrases vanish from the flat transcript too.
            newText = newSegments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        } else {
            let cleanedFull = cleanText(result.text, fillerWords: fillers)
            // No segments to rebuild from (or none dropped): still honour a whole-text match.
            newText = isIgnoredSegment(cleanedFull, ignored) ? "" : cleanedFull
        }

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
        // Asterisk-wrapped stage directions, e.g. "*music*" or "*laughs*" (single line).
        s = s.regexReplace(#"\*[^*\n]+\*"#, with: " ")

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
        // Strip leading/trailing dash runs Whisper sometimes prepends ("- text", "text —").
        s = s.regexReplace(#"^[\s\-–—]+"#, with: "")
        s = s.regexReplace(#"[\s\-–—]+$"#, with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a cleaned segment's text exactly matches one of the (already normalized)
    /// ignored phrases. Returns false when the ignore set is empty.
    static func isIgnoredSegment(_ text: String, _ normalizedIgnored: Set<String>) -> Bool {
        guard !normalizedIgnored.isEmpty else { return false }
        return normalizedIgnored.contains(normalizeForIgnoreMatch(text))
    }

    /// Normalize a phrase/segment for whole-segment ignore matching: lower-case, collapse
    /// inner whitespace, and trim surrounding whitespace and punctuation (so "Thank you for
    /// watching!" matches the stored "thank you for watching").
    static func normalizeForIgnoreMatch(_ text: String) -> String {
        let lowered = text.lowercased()
        let collapsed = lowered.regexReplace(#"\s+"#, with: " ")
        let trimChars = CharacterSet(charactersIn: " \t\n.,!?;:\"'`…-–—")
        return collapsed.trimmingCharacters(in: trimChars)
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
