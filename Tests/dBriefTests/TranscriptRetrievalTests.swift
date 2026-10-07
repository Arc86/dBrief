import Testing
import dBriefWire

@Suite struct TranscriptRetrievalTests {
    let count: (String) -> Int = { ($0.count + 3) / 4 }

    private func turns(_ n: Int) -> [TranscriptTurn] {
        (0..<n).map { TranscriptTurn(start: Double($0 * 10), end: Double($0 * 10 + 9), speaker: "S\($0 % 2)",
                                     text: "Turn \($0) about routine status updates and general planning.") }
    }

    @Test func windowsCoverEveryTurnWithinBudget() {
        let w = TranscriptRetrieval.windows(turns(200), targetTokens: 120, overlapTurns: 1, countTokens: count)
        #expect(w.count > 1)
        #expect(w.allSatisfy { count($0.text) <= 120 })
        for i in 0..<200 { #expect(w.contains { $0.text.contains("Turn \(i) ") }, "turn \(i)") }
        #expect(w.first!.text.hasPrefix("[00:00:00] S0: "))
        #expect(w.map(\.index) == Array(0..<w.count))
    }

    @Test func windowsOfNoTurnsAreEmpty() {
        #expect(TranscriptRetrieval.windows([], targetTokens: 120, overlapTurns: 1, countTokens: count).isEmpty)
    }

    @Test func bm25FindsRareTermAndIgnoresNonMatches() {
        var t = turns(50)
        t[37] = TranscriptTurn(start: 370, end: 379, speaker: "Marisol", text: "I will send the Kestrel contract to legal.")
        let w = TranscriptRetrieval.windows(t, targetTokens: 60, overlapTurns: 0, countTokens: count)
        let ranked = TranscriptRetrieval.bm25Ranking(query: "Who sends the kestrel contract?", windows: w)
        #expect(w[ranked[0]].text.contains("Kestrel"))
        #expect(TranscriptRetrieval.bm25Ranking(query: "zzzz", windows: w).isEmpty)
    }

    @Test func bm25OverNoWindowsIsEmpty() {
        #expect(TranscriptRetrieval.bm25Ranking(query: "anything", windows: []).isEmpty)
    }

    @Test func tokenizeFoldsCaseAndDiacritics() {
        #expect(TranscriptRetrieval.tokenize("Café BESLUIT, Q3!") == ["cafe", "besluit", "q3"])
    }

    @Test func cosineRankingOrdersBySimilarity() {
        let r = TranscriptRetrieval.cosineRanking(query: [1, 0], vectors: [[0, 1], [0.9, 0.1], [0.5, 0.5]])
        #expect(r == [1, 2, 0])
    }

    @Test func cosineRankingHandlesEmptyAndZeroVectors() {
        #expect(TranscriptRetrieval.cosineRanking(query: [1, 0], vectors: []).isEmpty)
        let r = TranscriptRetrieval.cosineRanking(query: [1, 0], vectors: [[0, 0], [1, 0]])
        #expect(r == [1, 0])
    }

    @Test func hybridRanksExactKeywordHit() {
        // Embeddings put window 2 last; BM25 puts it first; fusion must keep it in the top 2.
        let fused = TranscriptRetrieval.fuse([[0, 1, 3, 4, 2], [2]])
        #expect(fused.prefix(2).contains(2))
    }

    @Test func excerptsAreChronologicalIncludeNeighborsAndRespectBudget() {
        let w = TranscriptRetrieval.windows(turns(200), targetTokens: 120, overlapTurns: 0, countTokens: count)
        let text = TranscriptRetrieval.excerpts([10, 3], windows: w, budgetTokens: 800, neighbors: 1, countTokens: count)
        #expect(count(text) <= 800)
        let positions = [2, 3, 4, 9, 10, 11].map { text.range(of: w[$0].text)?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil })
        #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
        #expect(text.contains("…"))   // gap marker between non-adjacent groups
    }

    @Test func excerptsSkipOversizedWindowAndKeepGoing() {
        let big = TranscriptWindow(index: 0, start: 0, end: 9, text: String(repeating: "word ", count: 400))
        let small = TranscriptWindow(index: 1, start: 10, end: 19, text: "small window text")
        let text = TranscriptRetrieval.excerpts([0, 1], windows: [big, small], budgetTokens: 50,
                                                neighbors: 0, countTokens: count)
        #expect(text == "small window text")
        #expect(count(text) <= 50)
    }
}
