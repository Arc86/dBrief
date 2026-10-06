import Testing
import dBriefWire

@Suite struct AppleAnalysisBudgetTests {
    let count = AppleAnalysisBudget.estimateTokens

    @Test func budgetsFitTheContextWindow() {
        let b = AppleAnalysisBudget.from(contextSize: 4096)
        #expect(b.singlePassTranscriptTokens + b.finalResponseTokens <= 4096 * 80 / 100)  // ≥20% for instructions + margin
        #expect(b.chunkTokens + b.notesResponseTokens <= 4096 * 80 / 100)
        #expect(b.reduceInputTokens + b.finalResponseTokens <= 4096 * 80 / 100)
        #expect(b.finalResponseTokens >= 1_400)                                           // room for a real summary
        #expect(AppleAnalysisBudget.from(contextSize: 16_384).chunkTokens > b.chunkTokens)   // scales on macOS 27
    }

    @Test func withoutActionsKeepsEverythingElse() {
        let n = ChunkNotes(keyPoints: ["k"], decisions: ["d"], actionItems: ["[A] to x"], people: ["A"])
        #expect(NotesReducePlanner.withoutActions([n]) == [ChunkNotes(keyPoints: ["k"], decisions: ["d"], actionItems: [], people: ["A"])])
    }

    @Test func groupsFitBudgetKeepOrderAndCoverEveryNote() {
        let notes = (1...20).map { ChunkNotes(keyPoints: ["point \($0) " + String(repeating: "detail ", count: 30)],
                                             decisions: ["decision \($0)"], actionItems: [], people: []) }
        let groups = NotesReducePlanner.groups(notes, budget: 600, countTokens: count)
        #expect(groups.count > 1)
        #expect(groups.flatMap { $0 } == notes)
        #expect(groups.filter { $0.count > 1 }.allSatisfy {
            count(ChunkNotesMerger.reduceInput($0, maxTokens: .max, countTokens: count)) <= 600
        })
    }

    @Test func oversizedSingleNoteGetsItsOwnGroup() {
        let big = ChunkNotes(keyPoints: [String(repeating: "x ", count: 5_000)], decisions: [], actionItems: [], people: [])
        let small = ChunkNotes(keyPoints: ["s"], decisions: [], actionItems: [], people: [])
        #expect(NotesReducePlanner.groups([small, big, small], budget: 300, countTokens: count).map(\.count) == [1, 1, 1])
    }

    @Test func mergedConcatenatesInOrderDeduplicatesAndDropsActions() {
        let a = ChunkNotes(keyPoints: ["k1", "shared"], decisions: ["d1"], actionItems: ["[A] to x"], people: ["Ann"])
        let b = ChunkNotes(keyPoints: ["shared", "k2"], decisions: ["d2"], actionItems: ["[B] to y"], people: ["Ann", "Bob"])
        #expect(NotesReducePlanner.merged([a, b]) == ChunkNotes(keyPoints: ["k1", "shared", "k2"], decisions: ["d1", "d2"],
                                                              actionItems: [], people: ["Ann", "Bob"]))
    }

    @Test func guidedReducePromptHasNoJSONInstruction() {
        let p = UnifiedInsightsPrompt.reduceSystemPrompt(outputLanguage: .english, customVocabulary: "",
                                                         guidance: nil, forGuidedGeneration: true)
        #expect(!p.contains("JSON"))
        #expect(UnifiedInsightsPrompt.reduceSystemPrompt(outputLanguage: .english, customVocabulary: "", guidance: nil).contains("JSON"))
    }

    @Test func condensePromptKeepsDecisionsAndLanguage() {
        let p = UnifiedInsightsPrompt.condenseNotesSystemPrompt(outputLanguage: .dutch)
        #expect(p.contains("DUTCH") && p.contains("decision"))
    }
}
