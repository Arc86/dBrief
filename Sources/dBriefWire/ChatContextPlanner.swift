import Foundation

public enum ChatContextPlanner {
    /// Complete question/answer pairs, oldest first, excluding the in-flight turn.
    public static func history(from messages: [(role: ChatTurnMessage.Role, content: String)]) -> [ChatTurnMessage] {
        var out: [ChatTurnMessage] = []
        var pendingQuestion: String?
        for message in messages {
            switch message.role {
            case .user:
                pendingQuestion = message.content
            case .assistant:
                guard let q = pendingQuestion, !message.content.isEmpty else { pendingQuestion = nil; continue }
                out += [.init(role: .user, content: q), .init(role: .assistant, content: message.content)]
                pendingQuestion = nil
            }
        }
        return out
    }
}

extension ChatContextPlanner {
    public static func mode(transcriptTokens: Int, profile: ChatEngineProfile, hasOverview: Bool) -> ChatMode {
        guard transcriptTokens > profile.fullTranscriptTokens else { return .fullTranscript }
        return hasOverview ? .overviewAndRetrieval : .retrievalOnly
    }

    public static func compactHistory(_ history: [ChatTurnMessage], budget: Int,
                                      countTokens: (String) -> Int) -> String {
        guard budget > 0 else { return "" }
        var pairs: [String] = []
        var used = 0
        var i = history.count - 1
        while i >= 1 {
            let q = history[i - 1], a = history[i]
            guard q.role == .user, a.role == .assistant else { i -= 1; continue }
            let answer = a.content.count > 300 ? String(a.content.prefix(300)) + "…" : a.content
            let pair = "User: \(q.content)\nAssistant: \(answer)"
            let cost = countTokens(pair) + 1
            guard used + cost <= budget else { break }
            pairs.insert(pair, at: 0)
            used += cost
            i -= 2
        }
        return pairs.joined(separator: "\n")
    }

    public static func longModeSystemPrompt(overview: String, speakerLegend: String) -> String {
        var prompt = """
        You are an assistant answering questions about ONE long meeting recording. \
        It is too long to include in full. With each question you receive transcript excerpts \
        selected for that question; lines start with [hh:mm:ss] and the speaker's name.
        Rules:
        - Answer from the excerpts and the meeting overview below. Cite the timestamps you relied on, like [00:12:34].
        - If the answer is not in the excerpts or the overview, say so plainly. Do not guess.
        - Answer concisely in the transcript's language.
        """
        if !overview.isEmpty { prompt += "\n\n===== MEETING OVERVIEW =====\n\(overview)\n===== END OVERVIEW =====" }
        if !speakerLegend.isEmpty { prompt += "\n\nSPEAKER LEGEND:\n\(speakerLegend)" }
        return prompt
    }

    public static func retrievedContextBlock(_ excerpts: String) -> String {
        "===== TRANSCRIPT EXCERPTS FOR THIS QUESTION =====\n\(excerpts)\n===== END EXCERPTS ====="
    }

    /// User prompt for fresh-session engines (Apple Intelligence): history + excerpts + question.
    public static func freshSessionPrompt(history: String, excerpts: String, question: String) -> String {
        var parts: [String] = []
        if !history.isEmpty { parts.append("Previous conversation:\n\(history)") }
        if !excerpts.isEmpty { parts.append(retrievedContextBlock(excerpts)) }
        parts.append("QUESTION: \(question)")
        return parts.joined(separator: "\n\n")
    }
}
