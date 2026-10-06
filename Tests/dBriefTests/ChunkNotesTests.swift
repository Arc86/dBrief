import Foundation
import Testing
import dBriefWire

@Suite struct ChunkNotesTests {
    let count: (String) -> Int = { ($0.count + 3) / 4 }

    @Test func decodesSnakeCase() throws {
        let json = #"{"key_points":["a"],"decisions":[],"action_items":["[A] to x"],"people":["A"]}"#
        let notes = try JSONDecoder().decode(ChunkNotes.self, from: Data(json.utf8))
        #expect(notes.actionItems == ["[A] to x"])
    }

    @Test func mergedActionItemsKeepsOrderAndDropsOverlapDuplicates() {
        let a = ChunkNotes(keyPoints: [], decisions: [], actionItems: ["[Ann] to send deck", "[Bo] to book room"], people: [])
        let b = ChunkNotes(keyPoints: [], decisions: [], actionItems: ["[ann] to send deck.", "[Cy] to file report"], people: [])
        #expect(ChunkNotesMerger.mergedActionItems([a, b]) == ["[Ann] to send deck", "[Bo] to book room", "[Cy] to file report"])
    }

    @Test func mergedActionItemsNeverDropsDistinctItems() {
        let notes = (1...12).map { ChunkNotes(keyPoints: [], decisions: [], actionItems: ["[P\($0)] to do task \($0)"], people: []) }
        #expect(ChunkNotesMerger.mergedActionItems(notes).count == 12)
    }

    @Test(arguments: ["No action items were assigned in this segment.", "[Unassigned] No action items.",
                      "Geen actiepunten in dit deel.", "None", "n/a", "-", "[Unassigned] none.", "No tasks or commitments."])
    func placeholderActionItemsAreRecognized(item: String) {
        #expect(ChunkNotesMerger.isPlaceholderActionItem(item))
    }

    @Test(arguments: ["[Ann] to make sure no tasks are left open before Friday", "[Bo] to send the deck",
                      "Send the deck to legal", "[Cy] to note that no budget remains"])
    func realActionItemsAreKept(item: String) {
        #expect(!ChunkNotesMerger.isPlaceholderActionItem(item))
    }

    @Test func mergedActionItemsExcludesPlaceholdersAndKeepsOrder() {
        let a = ChunkNotes(keyPoints: [], decisions: [], actionItems: ["[Ann] to send deck", "No action items were assigned in this segment."], people: [])
        let b = ChunkNotes(keyPoints: [], decisions: [], actionItems: ["None"], people: [])
        let c = ChunkNotes(keyPoints: [], decisions: [], actionItems: ["[Unassigned] No action items.", "[Bo] to book room"], people: [])
        #expect(ChunkNotesMerger.mergedActionItems([a, b, c]) == ["[Ann] to send deck", "[Bo] to book room"])
    }

    @Test func chunkPromptForbidsPlaceholdersForDecisionsAndActions() {
        let sys = UnifiedInsightsPrompt.chunkNotesSystemPrompt(outputLanguage: .english, customVocabulary: "", guidance: nil)
        #expect(sys.contains("never write a placeholder such as 'No action items'"))
        #expect(sys.contains("never write a placeholder such as 'No decisions'"))
    }

    @Test func deduplicatedCollapsesRunawayRepeats() {
        let runaway = Array(repeating: "The CHRO role is evolving.", count: 50)
        let notes = ChunkNotes(keyPoints: runaway + ["the chro role is evolving"], decisions: ["D", "d."],
                               actionItems: ["[A] to x", "[a] to x"], people: ["Ann", "ann", "Bo"])
        let d = notes.deduplicated()
        #expect(d.keyPoints == ["The CHRO role is evolving."])
        #expect(d.decisions == ["D"])
        #expect(d.actionItems == ["[A] to x"])
        #expect(d.people == ["Ann", "Bo"])
    }

    @Test func deduplicatedKeepsDistinctItemsInOrder() {
        let notes = ChunkNotes(keyPoints: ["c", "a", "b"], decisions: ["2", "1"], actionItems: ["[Z] z", "[Y] y"], people: ["Bo", "Ann"])
        #expect(notes.deduplicated() == notes)
    }

    @Test func chunkPromptRulesFollowSchemaOrder() throws {
        let sys = UnifiedInsightsPrompt.chunkNotesSystemPrompt(outputLanguage: .english, customVocabulary: "", guidance: nil)
        let positions = try ["**action_items:**", "**decisions:**", "**people:**", "**key_points:**"].map {
            try #require(sys.range(of: $0)).lowerBound
        }
        #expect(positions == positions.sorted())
    }

    @Test func reduceInputIsOrderedAndLabelled() {
        let notes = [ChunkNotes(keyPoints: ["first"], decisions: ["d1"], actionItems: [], people: ["Ann"]),
                     ChunkNotes(keyPoints: ["second"], decisions: [], actionItems: ["[Bo] to x"], people: [])]
        let text = ChunkNotesMerger.reduceInput(notes, maxTokens: 10_000, countTokens: count)
        #expect(text.contains("PART 1 OF 2") && text.contains("PART 2 OF 2"))
        #expect(text.range(of: "first")!.lowerBound < text.range(of: "second")!.lowerBound)
    }

    @Test func reduceInputTrimsKeyPointsButKeepsDecisionsAndActions() {
        let long = (1...200).map { "Key point \($0) with plenty of descriptive words" }
        let notes = [ChunkNotes(keyPoints: long, decisions: ["KEEP-DECISION"], actionItems: ["[A] KEEP-ACTION"], people: [])]
        let text = ChunkNotesMerger.reduceInput(notes, maxTokens: 400, countTokens: count)
        #expect(count(text) <= 400)
        #expect(text.contains("KEEP-DECISION") && text.contains("KEEP-ACTION"))
        #expect(text.contains("Key point 1 ")) // earliest points survive
    }

    @Test func chunkPromptsCarryLanguageGuidanceAndContext() {
        let g = InsightsGuidance(summary: "Use ## headings", actionItems: "ACTION-GUIDE", tags: "TAG-GUIDE")
        let sys = UnifiedInsightsPrompt.chunkNotesSystemPrompt(outputLanguage: .dutch, customVocabulary: "dBrief", guidance: g)
        #expect(sys.contains("DUTCH") && sys.contains("ACTION-GUIDE") && sys.contains("dBrief"))
        let user = UnifiedInsightsPrompt.chunkNotesUserPrompt(context: "People likely in this meeting: Ann.",
            chunk: TranscriptChunk(index: 2, total: 5, text: "Ann: hi"))
        #expect(user.contains("PART 2 OF 5") && user.contains("Ann: hi") && user.contains("People likely"))
    }

    @Test func reducePromptKeepsSummaryAndTagGuidanceWithoutActionItemRule() {
        let g = InsightsGuidance(summary: "Use ## headings", actionItems: "ACTION-GUIDE", tags: "TAG-GUIDE")
        let sys = UnifiedInsightsPrompt.reduceSystemPrompt(outputLanguage: .english, customVocabulary: "", guidance: g)
        #expect(sys.contains("Use ## headings") && sys.contains("TAG-GUIDE"))
        #expect(!sys.contains("ACTION-GUIDE"))
        #expect(!sys.contains("action_items"))
    }

    @Test func mapAndReducePromptsForbidDoubleQuotesInJSONStrings() {
        let map = UnifiedInsightsPrompt.chunkNotesSystemPrompt(outputLanguage: .english, customVocabulary: "", guidance: nil)
        let reduce = UnifiedInsightsPrompt.reduceSystemPrompt(outputLanguage: .english, customVocabulary: "", guidance: nil)
        #expect(map.contains("never use the double-quote character"))
        #expect(reduce.contains("never use the double-quote character"))
    }
}
