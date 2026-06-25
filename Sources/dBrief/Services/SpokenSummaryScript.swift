import Foundation

/// Strips markdown / list / emphasis artifacts from an AI-generated script and
/// normalizes punctuation so the text-to-speech engine reads clean, fluent
/// spoken prose (ellipses, em-dashes, emoji and stray double spaces make
/// Qwen3-TTS hesitate or mis-intone). Pure (no IO), unit-tested.
enum SpokenSummaryScript {
    static func clean(_ raw: String) -> String {
        var lines: [String] = []
        for rawLine in raw.components(separatedBy: "\n") {
            var line = rawLine

            // Drop code-fence marker lines entirely (``` or ```lang), keep their inner text.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { continue }

            // Strip a leading list marker: "- ", "* ", "• ", "1. ", "2) ".
            if let r = line.range(of: #"^\s*([-*•]|\d+[.)])\s+"#, options: .regularExpression) {
                line.removeSubrange(r)
            }

            // Strip leading heading hashes: "## Title" -> "Title".
            if let r = line.range(of: #"^\s*#{1,6}\s*"#, options: .regularExpression) {
                line.removeSubrange(r)
            }

            // Remove emphasis / inline-code markers anywhere in the line.
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "*", with: "")
            line = line.replacingOccurrences(of: "`", with: "")

            lines.append(line)
        }

        var text = lines.joined(separator: "\n")

        // --- Speech normalization (TTS reads these badly otherwise) ---

        // Drop emoji / pictographs so the voice doesn't stumble over them.
        text = removingEmoji(text)

        // Ellipses → a clean sentence stop. Both the single glyph and "..".
        text = text.replacingOccurrences(of: "…", with: ". ")
        text = text.replacingOccurrences(of: #"\.{2,}"#, with: ". ", options: .regularExpression)

        // Em/en dash used as an aside separator → comma pause (keep hyphenated
        // words like "follow-up"). Bounded to spaces so it can't eat newlines.
        text = text.replacingOccurrences(of: #"[ \t]*[—–][ \t]*"#, with: ", ", options: .regularExpression)

        // Collapse runs of spaces/tabs and trim space before punctuation / line end.
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)

        // Collapse 3+ consecutive newlines into a paragraph break.
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove emoji/pictograph scalars (and their modifiers) while keeping plain
    /// text — digits and `#`/`*` are emoji-capable but text-presentation by
    /// default, so filtering on `isEmojiPresentation` leaves them intact.
    private static func removingEmoji(_ s: String) -> String {
        let scalars = s.unicodeScalars.filter { scalar in
            if scalar.properties.isEmojiPresentation { return false }
            if (0xFE00...0xFE0F).contains(scalar.value) { return false } // variation selectors
            if scalar.value == 0x200D { return false }                   // zero-width joiner
            if (0x1F3FB...0x1F3FF).contains(scalar.value) { return false } // skin-tone modifiers
            return true
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
