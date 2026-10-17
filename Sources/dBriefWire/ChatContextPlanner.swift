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

// MARK: - Whole-recording scan ("Check the whole recording")

extension ChatContextPlanner {
    /// Map step: ask for every relevant statement in ONE part, or exactly `NONE`.
    public static func scanPartPrompt(question: String, part: TranscriptChunk) -> (system: String, user: String) {
        (system: """
         You extract evidence from ONE PART of a long meeting transcript. Lines start with [hh:mm:ss] and the speaker.
         List every statement in this part that helps answer the question, each with its timestamp.
         If nothing in this part is relevant, reply with exactly: NONE
         """,
         user: "QUESTION: \(question)\n\nTRANSCRIPT PART \(part.index) OF \(part.total):\n\(part.text)")
    }

    /// True when a part's reply means "nothing relevant" (`NONE`, ignoring case,
    /// surrounding whitespace and punctuation such as `None.` or `**NONE**`).
    public static func isNoneFinding(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased() == "NONE"
    }

    /// Groups findings so each final prompt fits `budget`; one group on Gemma, several on Apple Intelligence.
    /// Findings keep their order and each lands in exactly one group. A multi-group result
    /// labels each group "Part a" or "Parts a–b" so the answers can be joined under headings.
    public static func scanFinalPrompts(question: String, findings: [(part: TranscriptChunk, text: String)],
                                        budget: Int, countTokens: (String) -> Int)
        -> [(label: String, system: String, user: String)] {
        scanFinalPromptsReport(question: question, findings: findings, budget: budget, countTokens: countTokens).prompts
    }

    /// `scanFinalPrompts` plus `clipped`: true when a last-resort clip shortened some
    /// evidence (only a single unsplittable line larger than the budget can need it).
    public static func scanFinalPromptsReport(question: String, findings: [(part: TranscriptChunk, text: String)],
                                              budget: Int, countTokens: (String) -> Int)
        -> (prompts: [(label: String, system: String, user: String)], clipped: Bool) {
        let system = """
        You answer a question about a long meeting from evidence collected across its parts.
        Use every relevant item; do not drop any. Cite timestamps like [00:12:34]. Answer in the transcript's language.
        """
        func user(_ group: [(part: TranscriptChunk, text: String)]) -> String {
            let body = group.map { "### PART \($0.part.index) OF \($0.part.total)\n\($0.text)" }.joined(separator: "\n\n")
            return "QUESTION: \(question)\n\nEVIDENCE:\n\(body.isEmpty ? "(no relevant evidence found)" : body)"
        }
        // A finding too large for a prompt of its own is split on line boundaries first,
        // each piece keeping its part, so grouping never has to cut evidence.
        var pieces: [(part: TranscriptChunk, text: String)] = []
        for finding in findings {
            guard countTokens(system + user([finding])) > budget else { pieces.append(finding); continue }
            let overhead = max(countTokens(system + user([])), countTokens(system + user([(finding.part, "")])))
            pieces += TranscriptChunkPlanner.plan(finding.text, maxTokensPerChunk: max(1, budget - overhead - 1),
                                                  overlapLines: 0, countTokens: countTokens)
                .map { (part: finding.part, text: $0.text) }
        }
        var groups: [[(part: TranscriptChunk, text: String)]] = [[]]
        for piece in pieces {
            let candidate = groups[groups.count - 1] + [piece]
            if !groups[groups.count - 1].isEmpty, countTokens(system + user(candidate)) > budget {
                groups.append([piece])
            } else {
                groups[groups.count - 1] = candidate
            }
        }
        // Last-resort guard: a single unsplittable line (one enormous word) can still exceed the budget.
        var clipped = false
        let prompts = groups.map { group in
            var u = user(group)
            while countTokens(system + u) > budget, u.count > 200 {
                u = String(u.prefix(u.count * 9 / 10)) + "…"
                clipped = true
            }
            let first = group.first?.part.index ?? 0, last = group.last?.part.index ?? 0
            let label = groups.count == 1 ? "" : first == last ? "Part \(first)" : "Parts \(first)–\(last)"
            return (label: label, system: system, user: u)
        }
        return (prompts, clipped)
    }
}
