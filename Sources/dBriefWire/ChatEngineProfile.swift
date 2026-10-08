import Foundation

/// Per-engine token budgets for transcript chat. Gemma's are fixed (tuned on the 75K-token
/// eval recording: 4K of excerpts kept recall while cutting follow-up latency);
/// Apple Intelligence's are fractions of the on-device model's context window, which
/// covers instructions + prompt + answer, so ~35% is left free for the answer.
public struct ChatEngineProfile: Sendable, Equatable {
    public let fullTranscriptTokens: Int
    public let excerptTokens: Int
    public let overviewTokens: Int
    /// Max tokens of earlier Q&A carried in the prompt (fresh-session engines only).
    public let historyTokens: Int
    public let scanPartTokens: Int
    public let scanFindingsTokens: Int
    public let reusesSession: Bool

    public init(fullTranscriptTokens: Int, excerptTokens: Int, overviewTokens: Int, historyTokens: Int,
                scanPartTokens: Int, scanFindingsTokens: Int, reusesSession: Bool) {
        self.fullTranscriptTokens = fullTranscriptTokens; self.excerptTokens = excerptTokens
        self.overviewTokens = overviewTokens; self.historyTokens = historyTokens
        self.scanPartTokens = scanPartTokens; self.scanFindingsTokens = scanFindingsTokens
        self.reusesSession = reusesSession
    }

    public static let gemma = ChatEngineProfile(
        fullTranscriptTokens: 24_000, excerptTokens: 4_000, overviewTokens: 8_000,
        historyTokens: 0, scanPartTokens: 10_000, scanFindingsTokens: 16_000, reusesSession: true)

    public static func appleIntelligence(contextSize: Int) -> ChatEngineProfile {
        func pct(_ p: Int) -> Int { contextSize * p / 100 }
        return ChatEngineProfile(
            fullTranscriptTokens: pct(55), excerptTokens: pct(30), overviewTokens: pct(25),
            historyTokens: pct(10), scanPartTokens: pct(55), scanFindingsTokens: pct(60), reusesSession: false)
    }

    /// Used for one retry after a context-overflow error. The full-transcript budget
    /// shrinks too, so a transcript that only just fit can fall into long mode.
    public func shrunk() -> ChatEngineProfile {
        ChatEngineProfile(fullTranscriptTokens: fullTranscriptTokens * 3 / 4, excerptTokens: excerptTokens / 2,
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
        guard countTokens(kept + "…") <= budget else { return "" }
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

/// Wording for the "Check the whole recording" button. Gemma's scan was measured at
/// ~6 ms of wall time per transcript token (8 sequential parts, 459 s for 75K tokens on an
/// M-series Mac); Apple Intelligence has no measured rate, so it stays vague.
public enum ChatScanEstimate {
    public static let gemmaSecondsPerToken = 0.0061

    public static func label(isGemma: Bool, transcriptTokens: Int) -> String {
        guard isGemma else { return "takes a few minutes" }
        let minutes = max(1, Int((Double(transcriptTokens) * gemmaSecondsPerToken / 60).rounded()))
        return minutes == 1 ? "about a minute" : "about \(minutes) minutes"
    }
}
