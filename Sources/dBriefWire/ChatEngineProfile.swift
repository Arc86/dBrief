import Foundation

/// Per-engine token budgets for transcript chat. Gemma's are fixed (tuned in Task 13);
/// Apple Intelligence's are fractions of the on-device model's context window, which
/// covers instructions + prompt + answer, so ~30% is left free for the answer.
public struct ChatEngineProfile: Sendable, Equatable {
    public let fullTranscriptTokens: Int
    public let excerptTokens: Int
    public let overviewTokens: Int
    /// Max tokens of earlier Q&A carried in the prompt (fresh-session engines only).
    public let historyTokens: Int
    public let scanPartTokens: Int
    public let scanFindingsTokens: Int
    public let reusesSession: Bool

    public static let gemma = ChatEngineProfile(
        fullTranscriptTokens: 24_000, excerptTokens: 6_000, overviewTokens: 8_000,
        historyTokens: 0, scanPartTokens: 10_000, scanFindingsTokens: 16_000, reusesSession: true)

    public static func appleIntelligence(contextSize: Int) -> ChatEngineProfile {
        func pct(_ p: Int) -> Int { contextSize * p / 100 }
        return ChatEngineProfile(
            fullTranscriptTokens: pct(55), excerptTokens: pct(40), overviewTokens: pct(15),
            historyTokens: pct(10), scanPartTokens: pct(55), scanFindingsTokens: pct(60), reusesSession: false)
    }

    /// Used for one retry after a context-overflow error.
    public func shrunk() -> ChatEngineProfile {
        ChatEngineProfile(fullTranscriptTokens: fullTranscriptTokens, excerptTokens: excerptTokens / 2,
                          overviewTokens: overviewTokens / 2, historyTokens: 0, scanPartTokens: scanPartTokens * 3 / 4,
                          scanFindingsTokens: scanFindingsTokens * 3 / 4, reusesSession: reusesSession)
    }

    public static func estimateTokens(_ text: String) -> Int { (text.count + 2) / 3 }
}

public enum ChatMode: Equatable, Sendable { case fullTranscript, overviewAndRetrieval, retrievalOnly }

/// Whole-meeting overview sized to an engine: part notes when they fit, else the
/// saved summary + action items, else the summary cut at a sentence boundary.
public enum ChatOverview {
    public static func make(notes: [ChunkNotes]?, summary: String?, actionItems: [String],
                            budget: Int, countTokens: (String) -> Int) -> String {
        guard budget > 0 else { return "" }
        if let notes, !notes.isEmpty {
            let header = "MEETING NOTES (whole meeting, in order):\n"
            let body = ChunkNotesMerger.reduceInput(notes, maxTokens: budget - countTokens(header), countTokens: countTokens)
            if countTokens(header + body) <= budget { return header + body }
        }
        guard let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return "" }
        let summaryBlock = "MEETING SUMMARY:\n" + summary
        let actions = actionItems.isEmpty ? "" : "\n\nACTION ITEMS:\n" + actionItems.map { "- \($0)" }.joined(separator: "\n")
        if countTokens(summaryBlock + actions) <= budget { return summaryBlock + actions }
        if countTokens(summaryBlock) <= budget { return summaryBlock }
        var kept = "MEETING SUMMARY:\n"
        let sentences = summary.split(separator: " ").reduce(into: [String]()) { acc, word in
            if let last = acc.last, !(last.hasSuffix(".") || last.hasSuffix("!") || last.hasSuffix("?")) {
                acc[acc.count - 1] = last + " " + word
            } else { acc.append(String(word)) }
        }
        for sentence in sentences {
            guard countTokens(kept + sentence + " …") <= budget else { break }
            kept += sentence + " "
        }
        return kept + "…"
    }
}
