import Foundation

/// Structured notes for one transcript part (map step of long-transcript analysis).
public struct ChunkNotes: Codable, Sendable, Equatable {
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [String]
    public var people: [String]

    public init(keyPoints: [String], decisions: [String], actionItems: [String], people: [String]) {
        self.keyPoints = keyPoints; self.decisions = decisions
        self.actionItems = actionItems; self.people = people
    }

    enum CodingKeys: String, CodingKey {
        case keyPoints = "key_points", decisions, actionItems = "action_items", people
    }

    /// Removes exact repeats inside each list (same normalization as
    /// `ChunkNotesMerger.mergedActionItems`), keeping first-seen order. Collapses a
    /// runaway list that repeats one item until the output cap.
    public func deduplicated() -> ChunkNotes {
        func unique(_ items: [String]) -> [String] {
            var seen = Set<String>()
            return items.filter { seen.insert(ChunkNotesMerger.normalize($0)).inserted }
        }
        return ChunkNotes(keyPoints: unique(keyPoints), decisions: unique(decisions),
                          actionItems: unique(actionItems), people: unique(people))
    }
}

public enum ChunkNotesMerger {
    /// Union of every part's action items in transcript order. Only items whose
    /// normalized text is identical (the overlap between neighbouring parts) are
    /// merged; nothing is re-summarized, so no commitment can be dropped.
    public static func mergedActionItems(_ notes: [ChunkNotes]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in notes.flatMap(\.actionItems) {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalize(trimmed)
            guard !key.isEmpty, !isPlaceholderActionItem(trimmed), seen.insert(key).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// True for filler such as "No action items were assigned in this segment." or
    /// "[Unassigned] None." that a model writes instead of an empty list; these would
    /// otherwise become fake reminders. Deliberately narrow: an item is never dropped
    /// just for lacking a `[WHO]` prefix.
    public static func isPlaceholderActionItem(_ item: String) -> Bool {
        var text = item.trimmingCharacters(in: .whitespacesAndNewlines)
        if let owner = text.range(of: #"^\[[^\]]*\]"#, options: .regularExpression) {
            text.removeSubrange(owner)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        if text.isEmpty || ["none", "n/a", "geen", "nvt"].contains(text) { return true }
        guard text.hasPrefix("no ") || text.hasPrefix("none") || text.hasPrefix("geen") else { return false }
        let topics = ["action item", "task", "commitment", "actiepunt", "taken", "afspraken"]
        return topics.contains { text.contains($0) }
    }

    /// Renders notes for the reduce prompt. When over `maxTokens`, drops the
    /// latest key points from the largest part first; decisions, action items and
    /// people are never trimmed.
    public static func reduceInput(_ notes: [ChunkNotes], maxTokens: Int, countTokens: (String) -> Int) -> String {
        var working = notes
        var text = render(working)
        while countTokens(text) > maxTokens,
              let largest = working.indices.filter({ !working[$0].keyPoints.isEmpty })
                .max(by: { working[$0].keyPoints.count < working[$1].keyPoints.count }) {
            working[largest].keyPoints.removeLast()
            text = render(working)
        }
        return text
    }

    private static func render(_ notes: [ChunkNotes]) -> String {
        notes.enumerated().map { offset, n in
            var lines = ["### PART \(offset + 1) OF \(notes.count)"]
            func section(_ title: String, _ items: [String]) {
                guard !items.isEmpty else { return }
                lines.append("\(title):")
                lines.append(contentsOf: items.map { "- \($0)" })
            }
            section("Key points", n.keyPoints)
            section("Decisions", n.decisions)
            section("Action items", n.actionItems)
            section("People", n.people)
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
