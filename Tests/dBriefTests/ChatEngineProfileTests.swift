import Testing
import dBriefWire

@Suite struct ChatEngineProfileTests {
    let count = ChatEngineProfile.estimateTokens

    @Test func appleBudgetsLeaveRoomForTheAnswer() {
        let p = ChatEngineProfile.appleIntelligence(contextSize: 4096)
        #expect(p.overviewTokens + p.historyTokens + p.excerptTokens <= 4096 * 70 / 100)
        #expect(p.fullTranscriptTokens <= 4096 * 60 / 100)
        #expect(!p.reusesSession)
        #expect(ChatEngineProfile.appleIntelligence(contextSize: 16_384).excerptTokens > p.excerptTokens) // scales on macOS 27
    }

    @Test func gemmaKeepsLargerBudgetsAndSessionReuse() {
        #expect(ChatEngineProfile.gemma.reusesSession)
        #expect(ChatEngineProfile.gemma.excerptTokens > ChatEngineProfile.appleIntelligence(contextSize: 4096).excerptTokens)
    }

    @Test func shrunkHalvesExcerptsAndDropsHistory() {
        let p = ChatEngineProfile.appleIntelligence(contextSize: 4096).shrunk()
        #expect(p.historyTokens == 0)
        #expect(p.excerptTokens == ChatEngineProfile.appleIntelligence(contextSize: 4096).excerptTokens / 2)
    }

    /// A transcript that only just fit full mode must be able to fall into long mode on
    /// the overflow retry (estimated tokens can undercount).
    @Test func shrunkCutsFullTranscriptBudgetSoRetryCanUseLongMode() {
        let base = ChatEngineProfile.appleIntelligence(contextSize: 4096)
        let p = base.shrunk()
        #expect(p.fullTranscriptTokens == base.fullTranscriptTokens * 3 / 4)
        let nearlyFull = base.fullTranscriptTokens - 10
        #expect(ChatContextPlanner.mode(transcriptTokens: nearlyFull, profile: base, hasOverview: true) == .fullTranscript)
        #expect(ChatContextPlanner.mode(transcriptTokens: nearlyFull, profile: p, hasOverview: true) == .overviewAndRetrieval)
    }

    @Test func modeSelection() {
        let apple = ChatEngineProfile.appleIntelligence(contextSize: 4096)
        #expect(ChatContextPlanner.mode(transcriptTokens: 1_000, profile: apple, hasOverview: false) == .fullTranscript)
        #expect(ChatContextPlanner.mode(transcriptTokens: 10_000, profile: apple, hasOverview: true) == .overviewAndRetrieval)
        #expect(ChatContextPlanner.mode(transcriptTokens: 10_000, profile: .gemma, hasOverview: true) == .fullTranscript)
        #expect(ChatContextPlanner.mode(transcriptTokens: 60_000, profile: .gemma, hasOverview: false) == .retrievalOnly)
    }

    @Test func overviewPrefersNotesWhenTheyFit() {
        let notes = (1...6).map { ChunkNotes(keyPoints: ["kp\($0)"], decisions: ["d\($0)"], actionItems: [], people: []) }
        let o = ChatOverview.make(notes: notes, summary: "SUMMARY", actionItems: [], budget: 8_000, countTokens: count)
        for i in 1...6 { #expect(o.contains("kp\(i)")) }
        #expect(!o.contains("SUMMARY"))
    }

    @Test func overviewFallsBackToSummaryWhenNotesDoNotFit() {
        let notes = (1...40).map { _ in ChunkNotes(keyPoints: [], decisions: [String(repeating: "decision text ", count: 20)],
                                              actionItems: [], people: []) }
        let o = ChatOverview.make(notes: notes, summary: "The team approved the budget.", actionItems: ["[Ann] to send deck"],
                                  budget: 600, countTokens: count)
        #expect(o.contains("approved the budget") && o.contains("[Ann] to send deck"))
        #expect(count(o) <= 600)
    }

    @Test func overviewCutsSummaryAtSentenceBoundaryWithinBudget() {
        let summary = (1...200).map { "Sentence \($0) of the summary." }.joined(separator: " ")
        let o = ChatOverview.make(notes: nil, summary: summary, actionItems: [], budget: 300, countTokens: count)
        #expect(count(o) <= 300)
        #expect(o.contains("Sentence 1 of") && o.hasSuffix("…"))
    }

    @Test func overviewEmptyWhenEvenTheHeaderCannotFit() {
        let o = ChatOverview.make(notes: nil, summary: "A real summary. It has two sentences.", actionItems: [], budget: 3, countTokens: count)
        #expect(o.isEmpty && count(o) <= 3)
    }

    @Test func overviewSummaryOnlyFallbackDropsActionsWhole() {
        let summary = "The team approved the budget."
        let actions = (1...50).map { "[Ann] to send deck number \($0) to everyone" }
        let o = ChatOverview.make(notes: nil, summary: summary, actionItems: actions, budget: 30, countTokens: count)
        #expect(o.contains("approved the budget"))
        #expect(!o.contains("ACTION ITEMS") && !o.contains("deck number"))
        #expect(count(o) <= 30)
    }

    @Test func overviewEmptyWhenNothingAvailable() {
        #expect(ChatOverview.make(notes: nil, summary: nil, actionItems: [], budget: 600, countTokens: count).isEmpty)
    }

    @Test func compactHistoryKeepsNewestPairsWithinBudget() {
        let history = (1...10).flatMap { [ChatTurnMessage(role: .user, content: "Q\($0)"),
                                          ChatTurnMessage(role: .assistant, content: String(repeating: "answer \($0) ", count: 30))] }
        let text = ChatContextPlanner.compactHistory(history, budget: 200, countTokens: count)
        #expect(count(text) <= 200)
        #expect(text.contains("Q10") && !text.contains("Q1\n"))
        #expect(text.range(of: "Q9").map { $0.lowerBound < text.range(of: "Q10")!.lowerBound } ?? true) // chronological
        #expect(ChatContextPlanner.compactHistory(history, budget: 0, countTokens: count).isEmpty)
    }

    @Test func longModePromptsExplainExcerptsAndHonesty() {
        let system = ChatContextPlanner.longModeSystemPrompt(overview: "OVERVIEW", speakerLegend: "- S1: Alice")
        #expect(system.contains("OVERVIEW") && system.contains("excerpts") && system.contains("not in the excerpts"))
        let user = ChatContextPlanner.freshSessionPrompt(history: "User: Q1\nAssistant: A1", excerpts: "[00:01:00] A: x", question: "Q2")
        #expect(user.contains("Q1") && user.contains("[00:01:00]") && user.hasSuffix("QUESTION: Q2"))
        #expect(!ChatContextPlanner.freshSessionPrompt(history: "", excerpts: "e", question: "q").contains("Previous conversation"))
    }

    @Test func scanEstimateIsConcreteForGemmaOnly() {
        #expect(ChatScanEstimate.label(isGemma: true, transcriptTokens: 75_000) == "about 8 minutes")
        #expect(ChatScanEstimate.label(isGemma: true, transcriptTokens: 1_000) == "about a minute")
        #expect(ChatScanEstimate.label(isGemma: false, transcriptTokens: 75_000) == "takes a few minutes")
    }
}
