import Foundation

enum ObsidianFormatter {
    private static let defaultConcept = "Meeting Notes"

    static func format(transcript: String, insights: LocalInsightsResult, includeTranscript: Bool = false) -> String {
        let now = Date()
        let dateString = formatDate(now)
        let concept = insights.titleConcept.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = "\(dateString) - \((concept.isEmpty ? defaultConcept : concept))"
        let summary = insights.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentiment = sentimentLabel(for: insights.sentiment)

        let checklistItems = insights.actionItems
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let tags = insights.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { tag in
                let sanitized = tag.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
                return "#\(sanitized.lowercased())"
            }

        var lines: [String] = []
        lines.append("# \(finalTitle)")
        lines.append("**Date:** \(dateString)")
        lines.append("**Sentiment:** \(sentiment)")
        lines.append("")
        lines.append("## 📝 Summary")
        lines.append(summary.isEmpty ? "No summary available." : summary)
        lines.append("")
        lines.append("## ✅ Action Items")
        if checklistItems.isEmpty {
            lines.append("- [ ] No action items identified")
        } else {
            lines.append(contentsOf: checklistItems.map { "- [ ] \($0)" })
        }
        lines.append("")
        lines.append("## 🏷️ Tags")
        lines.append(tags.isEmpty ? "#untagged" : tags.joined(separator: " "))

        if includeTranscript {
            let cleanedTranscript = cleanWhisperTimestamps(in: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
            lines.append("---")
            lines.append("## 💬 Transcript")
            lines.append(cleanedTranscript.isEmpty ? "No transcript available." : cleanedTranscript)
        }

        return lines.joined(separator: "\n")
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func sentimentLabel(for sentiment: String) -> String {
        switch sentiment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "positive":
            return "🟢 Positive"
        case "negative":
            return "🔴 Negative"
        default:
            return "😐 Neutral"
        }
    }

    private static func cleanWhisperTimestamps(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<\|([0-9.]+)\|>"#) else {
            return text
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        if matches.isEmpty {
            return text
        }

        var result = text
        for match in matches.reversed() {
            guard
                match.numberOfRanges > 1,
                let fullRange = Range(match.range(at: 0), in: result),
                let secondsRange = Range(match.range(at: 1), in: result),
                let seconds = Double(result[secondsRange])
            else { continue }

            let replacement = "**[\(formatSeconds(seconds))]**"
            result.replaceSubrange(fullRange, with: replacement)
        }

        return result
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
