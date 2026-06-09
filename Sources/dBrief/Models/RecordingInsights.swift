import Foundation

/// AI analysis output persisted alongside a recording as `<base>.insights.json`.
/// Written during processing and rewritten when the user edits the analysis in
/// the transcript window. Sentiment is display-only (never edited by the user).
struct RecordingInsights: Codable, Sendable, Equatable {
    var version: Int
    var summary: String
    var actionItems: [String]
    var tags: [String]
    var sentiment: String
    /// Absolute path of the markdown file generated for this recording, so an
    /// edit knows which `.md` to update. Nil/missing → markdown update skipped.
    var markdownPath: String?

    init(
        version: Int = 1,
        summary: String,
        actionItems: [String],
        tags: [String],
        sentiment: String,
        markdownPath: String?
    ) {
        self.version = version
        self.summary = summary
        self.actionItems = actionItems
        self.tags = tags
        self.sentiment = sentiment
        self.markdownPath = markdownPath
    }

    /// User-friendly plain text for the Copy button. Omits empty sections.
    func plainTextForCopy() -> String {
        var parts: [String] = []
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            parts.append("Summary\n\n\(trimmedSummary)")
        }
        if !actionItems.isEmpty {
            let body = actionItems.map { "- \($0)" }.joined(separator: "\n")
            parts.append("Action Items\n\n\(body)")
        }
        if !tags.isEmpty {
            let body = tags.map { "#\($0)" }.joined(separator: " ")
            parts.append("Tags\n\n\(body)")
        }
        let trimmedSentiment = sentiment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSentiment.isEmpty {
            parts.append("Sentiment: \(trimmedSentiment)")
        }
        return parts.joined(separator: "\n\n")
    }
}
