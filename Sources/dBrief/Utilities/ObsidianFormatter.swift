import Foundation

enum ObsidianFormatter {
    private static let defaultConcept = "Meeting Notes"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private static let timestampRegex = try? NSRegularExpression(pattern: #"<\|([0-9.]+)\|>"#)

    static func format(transcript: String, insights: LocalInsightsResult, includeTranscript: Bool = false) -> String {
        let now = Date()
        let dateString = dateFormatter.string(from: now)
        let dateTimeString = dateTimeFormatter.string(from: now)
        let isoString = isoFormatter.string(from: now)

        let concept = insights.titleConcept.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = concept.isEmpty ? defaultConcept : concept
        let summary = insights.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentimentRaw = insights.sentiment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let checklistItems = insights.actionItems
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let sanitizedTags = insights.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression).lowercased() }

        var lines: [String] = []

        // YAML frontmatter
        lines.append("---")
        lines.append("title: \"\(title)\"")
        lines.append("date: \(isoString)")
        if !sanitizedTags.isEmpty {
            lines.append("tags:")
            for tag in sanitizedTags {
                lines.append("  - \(tag)")
            }
        }
        lines.append("sentiment: \"\(sentimentRaw)\"")
        lines.append("---")
        lines.append("")

        // Title and metadata
        lines.append("# \(dateString) - \(title)")
        lines.append("")
        lines.append("**Date:** \(dateTimeString)")
        lines.append("**Sentiment:** \(sentimentLabel(for: insights.sentiment))")
        lines.append("")

        // Summary
        lines.append("## 📝 Summary")
        lines.append("")
        lines.append(summary.isEmpty ? "No summary available." : summary)
        lines.append("")

        // Action Items
        lines.append("## ✅ Action Items")
        lines.append("")
        if checklistItems.isEmpty {
            lines.append("- [ ] No action items identified")
        } else {
            lines.append(contentsOf: checklistItems.map { "- [ ] \($0)" })
        }
        lines.append("")

        // Tags
        lines.append("## 🏷️ Tags")
        lines.append("")
        lines.append(sanitizedTags.isEmpty ? "#untagged" : sanitizedTags.map { "#\($0)" }.joined(separator: " "))

        if includeTranscript {
            let cleanedTranscript = cleanWhisperTimestamps(in: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
            lines.append("---")
            lines.append("## 💬 Transcript")
            lines.append("")
            lines.append(cleanedTranscript.isEmpty ? "No transcript available." : cleanedTranscript)
        }

        return lines.joined(separator: "\n")
    }

    private static func sentimentLabel(for sentiment: String) -> String {
        switch sentiment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "positive": return "🟢 Positive"
        case "negative": return "🔴 Negative"
        default:         return "😐 Neutral"
        }
    }

    private static func cleanWhisperTimestamps(in text: String) -> String {
        guard let regex = timestampRegex else { return text }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard
                match.numberOfRanges > 1,
                let fullRange = Range(match.range(at: 0), in: result),
                let secondsRange = Range(match.range(at: 1), in: result),
                let seconds = Double(result[secondsRange])
            else { continue }

            result.replaceSubrange(fullRange, with: "**[\(formatSeconds(seconds))]**")
        }

        return result
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
