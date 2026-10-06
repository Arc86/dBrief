import Foundation

/// Token budgets for Apple Intelligence analysis, derived from the on-device model's
/// context window (`SystemLanguageModel.default.contextSize`: 4096 on macOS 26), which
/// must hold instructions + transcript/notes + the generated answer. 15% is reserved
/// for instructions (user guidance can be long) and 5% as margin.
public struct AppleAnalysisBudget: Sendable, Equatable {
    public let singlePassTranscriptTokens: Int
    public let chunkTokens: Int
    public let notesResponseTokens: Int
    public let reduceInputTokens: Int
    public let finalResponseTokens: Int

    public static func from(contextSize: Int) -> AppleAnalysisBudget {
        func pct(_ p: Int) -> Int { contextSize * p / 100 }
        let final = max(pct(37), min(1_500, pct(45)))
        return AppleAnalysisBudget(
            singlePassTranscriptTokens: pct(80) - final,
            chunkTokens: pct(62),
            notesResponseTokens: pct(18),
            reduceInputTokens: pct(80) - final,
            finalResponseTokens: final)
    }

    /// Conservative estimate (~3 characters per token) for when the exact count is unavailable.
    public static func estimateTokens(_ text: String) -> Int { (text.count + 2) / 3 }
}

public enum NotesReducePlanner {
    /// Action items are merged deterministically from the map notes; they never pass
    /// through condense/reduce, so the model cannot drop one.
    public static func withoutActions(_ notes: [ChunkNotes]) -> [ChunkNotes] {
        notes.map { ChunkNotes(keyPoints: $0.keyPoints, decisions: $0.decisions, actionItems: [], people: $0.people) }
    }

    /// One note holding a group's notes in order, without the model (the fallback when
    /// a condense call fails): exact repeats removed, action items left out.
    public static func merged(_ group: [ChunkNotes]) -> ChunkNotes {
        ChunkNotes(keyPoints: group.flatMap(\.keyPoints), decisions: group.flatMap(\.decisions),
                   actionItems: [], people: group.flatMap(\.people)).deduplicated()
    }

    /// Consecutive groups whose rendered reduce input fits `budget`. A note that alone
    /// exceeds the budget forms its own group (trimmed later by `ChunkNotesMerger.reduceInput`).
    public static func groups(_ notes: [ChunkNotes], budget: Int, countTokens: (String) -> Int) -> [[ChunkNotes]] {
        var out: [[ChunkNotes]] = []
        var current: [ChunkNotes] = []
        for note in notes {
            let candidate = current + [note]
            if !current.isEmpty,
               countTokens(ChunkNotesMerger.reduceInput(candidate, maxTokens: .max, countTokens: countTokens)) > budget {
                out.append(current)
                current = [note]
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// Plain-text form of `ChunkNotes`, for when Apple Intelligence refuses guided
/// generation of a part (a false-positive refusal on benign meeting text) but answers
/// the same request as free text. Tolerant of Markdown headings, snake_case headings
/// and bullet styles; text before the first heading is ignored. `nil` when the text has
/// no heading at all (e.g. a refusal sentence), so it is never mistaken for empty notes. Pure.
public enum ChunkNotesTextFormat {
    public static let instruction = """
    Write the notes as four sections with exactly these headings, each followed by one '- ' bullet per item. \
    Leave a section empty when it has nothing.
    ACTION ITEMS:
    DECISIONS:
    PEOPLE:
    KEY POINTS:
    """

    private enum Section { case actionItems, decisions, people, keyPoints }
    private static let headings: [String: Section] = [
        "action items": .actionItems, "decisions": .decisions, "people": .people, "key points": .keyPoints,
    ]

    public static func parse(_ text: String) -> ChunkNotes? {
        var notes = ChunkNotes(keyPoints: [], decisions: [], actionItems: [], people: [])
        var section: Section?
        func add(_ item: String) {
            let item = item.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "*")))
            guard !item.isEmpty, let section else { return }
            switch section {
            case .actionItems: notes.actionItems.append(item)
            case .decisions: notes.decisions.append(item)
            case .people: notes.people.append(item)
            case .keyPoints: notes.keyPoints.append(item)
            }
        }
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let bulletless = stripBullet(line) { line = bulletless }
            // A heading may itself be bulleted ("- **Action Items:**").
            if let (heading, rest) = heading(line) { section = heading; add(rest); continue }
            add(line)
        }
        return section == nil ? nil : notes.deduplicated()
    }

    /// The item text when `line` starts with a bullet ("-", "*", "•") or a number ("1." / "2)").
    private static func stripBullet(_ line: String) -> String? {
        if let first = line.first, "-*•".contains(first), line.dropFirst().first == " " {
            return String(line.dropFirst(2))
        }
        let digits = line.prefix(while: \.isNumber)
        let after = line.dropFirst(digits.count)
        if !digits.isEmpty, let mark = after.first, ".)".contains(mark), after.dropFirst().first == " " {
            return String(after.dropFirst(2))
        }
        return nil
    }

    private static func heading(_ line: String) -> (Section, String)? {
        let stripped = line.drop(while: { "#* ".contains($0) })
        let parts = stripped.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let key = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "* ")).lowercased()
            .replacingOccurrences(of: "_", with: " ")
        guard let section = headings[key] else { return nil }
        return (section, parts.count > 1 ? String(parts[1]) : "")
    }
}

/// Recognises a model's short refusal sentence returned as plain text (the free-text
/// fallback answers "I apologize, but I cannot fulfill this request." instead of
/// throwing), so it is never saved as a summary. English only: the on-device model
/// refuses in English. Pure.
public enum RefusalText {
    private static let openings = ["i apologize", "i'm sorry", "i’m sorry", "i am sorry", "sorry", "i cannot", "i can't", "i can’t"]

    public static func isRefusal(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !t.isEmpty && t.count < 200 && openings.contains { t.hasPrefix($0) }
    }
}
