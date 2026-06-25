import Foundation

/// Strips markdown / list / emphasis artifacts from an AI-generated script so the
/// text-to-speech engine reads clean spoken prose. Pure (no IO), unit-tested.
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

        // Collapse 3+ consecutive newlines into a paragraph break.
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
