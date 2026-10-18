import Foundation

/// What every "Copy Notes" button copies: the summary, then the action items, or the
/// plain transcript when the recording has no analysis.
enum RecordingNotesText {
    static func compose(summary: String?, actionItems: [String]?, transcript: String?) -> String? {
        var parts: [String] = []
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            parts.append("## Summary\n\(summary)")
        }
        let items = ActionItemText.deliverable(actionItems ?? []).map(\.title)
        if !items.isEmpty { parts.append("## Action Items\n" + items.map { "- \($0)" }.joined(separator: "\n")) }
        if parts.isEmpty, let transcript = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
            return transcript
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Notes for a saved recording: the insights sidecar, else the Markdown note's
    /// summary section (older recordings), else the saved transcript.
    static func load(for audioURL: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let base = audioURL.deletingPathExtension()
            if let data = try? Data(contentsOf: base.appendingPathExtension("insights.json")),
               let insights = try? JSONDecoder().decode(RecordingInsights.self, from: data),
               let text = compose(summary: insights.summary, actionItems: insights.actionItems, transcript: nil) {
                return text
            }
            if let markdown = try? String(contentsOf: base.appendingPathExtension("md"), encoding: .utf8),
               let summary = section(MarkdownInsightsUpdater.summaryHeader, in: markdown),
               let text = compose(summary: summary, actionItems: section(MarkdownInsightsUpdater.actionItemsHeader, in: markdown)?
                .components(separatedBy: "\n"), transcript: nil) {
                return text
            }
            if let data = try? Data(contentsOf: base.appendingPathExtension("transcript.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return compose(summary: nil, actionItems: nil, transcript: json["text"] as? String)
            }
            return nil
        }.value
    }

    private static func section(_ header: String, in markdown: String) -> String? {
        var lines: [String] = []
        var inside = false
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix(header) { inside = true; continue }
            if inside {
                if line.hasPrefix("## ") { break }
                lines.append(line)
            }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return inside && !text.isEmpty ? text : nil
    }
}
