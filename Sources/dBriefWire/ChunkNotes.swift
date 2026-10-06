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
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(trimmed)
        }
        return out
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

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
