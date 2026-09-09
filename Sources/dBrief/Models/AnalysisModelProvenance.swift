import Foundation

/// Generation origin of each independently replaceable analysis field. User
/// edits retain this origin; it is not a claim that every edited word was generated.
/// Missing origins on legacy or externally created outputs stay unknown.
struct AnalysisModelProvenance: Codable, Equatable, Sendable {
    var summary: String? = nil
    var actionItems: String? = nil
    /// Tags and sentiment are returned by the same model call.
    var tags: String? = nil

    /// The legacy singular Markdown key is truthful only for a common known
    /// origin of every present field. Never guess from current settings.
    func modelName(summary: String, actionItems: [String], tags: [String], sentiment: String) -> String? {
        var origins: [String?] = []
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { origins.append(self.summary) }
        if actionItems.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            origins.append(self.actionItems)
        }
        if tags.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            || !sentiment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { origins.append(self.tags) }
        let known = origins.compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        guard !known.isEmpty, known.count == origins.count, Set(known).count == 1 else { return nil }
        return known[0]
    }
}
