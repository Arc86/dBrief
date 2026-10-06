import Testing
import dBriefWire

@Suite struct TranscriptChunkPlannerTests {
    let count: (String) -> Int = { ($0.count + 3) / 4 }

    private func lines(_ n: Int, chars: Int = 80) -> String {
        (1...n).map { "Speaker \($0 % 3): " + String(repeating: "w", count: chars) + " L\($0)." }
            .joined(separator: "\n")
    }

    @Test func withinBudgetIsSingleUnchangedChunk() {
        let t = lines(10)
        let chunks = TranscriptChunkPlanner.plan(t, maxTokensPerChunk: 10_000, overlapLines: 2, countTokens: count)
        #expect(chunks == [TranscriptChunk(index: 1, total: 1, text: t)])
    }

    @Test func emptyTranscriptIsSingleEmptyChunk() {
        #expect(TranscriptChunkPlanner.plan("", maxTokensPerChunk: 100, overlapLines: 2, countTokens: count).count == 1)
    }

    @Test func everyChunkFitsAndEveryLineIsCovered() {
        let t = lines(400)
        let chunks = TranscriptChunkPlanner.plan(t, maxTokensPerChunk: 1_000, overlapLines: 2, countTokens: count)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { count($0.text) <= 1_000 })
        #expect(chunks.map(\.total).allSatisfy { $0 == chunks.count })
        #expect(chunks.map(\.index) == Array(1...chunks.count))
        for i in 1...400 { #expect(chunks.contains { $0.text.contains(" L\(i).") }, "line \(i) lost") }
    }

    @Test func consecutiveChunksOverlapByRequestedLines() {
        let chunks = TranscriptChunkPlanner.plan(lines(400), maxTokensPerChunk: 1_000, overlapLines: 2, countTokens: count)
        let tail = chunks[0].text.split(separator: "\n").suffix(2)
        let head = chunks[1].text.split(separator: "\n").prefix(2)
        #expect(Array(tail) == Array(head))
    }

    @Test func singleLineTranscriptIsSplitOnSentences() {
        // No diarization → one line (F8).
        let t = (1...300).map { "Sentence number \($0) has some words in it." }.joined(separator: " ")
        let chunks = TranscriptChunkPlanner.plan(t, maxTokensPerChunk: 500, overlapLines: 1, countTokens: count)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { count($0.text) <= 500 })
        #expect(chunks.last!.text.contains("number 300 "))
        #expect(chunks.first!.text.hasPrefix("Sentence number 1 "))
    }

    @Test func runOnTextWithoutPunctuationIsSplitOnWords() {
        let t = Array(repeating: "word", count: 5_000).joined(separator: " ")
        let chunks = TranscriptChunkPlanner.plan(t, maxTokensPerChunk: 300, overlapLines: 0, countTokens: count)
        #expect(chunks.allSatisfy { count($0.text) <= 300 })
        #expect(chunks.map { $0.text.split(whereSeparator: \.isWhitespace).count }.reduce(0, +) == 5_000)
    }

    @Test func singleWordLongerThanBudgetIsKeptWhole() {
        let giant = String(repeating: "x", count: 2_000) // 500 tokens > budget 100
        let t = "alpha beta \(giant) gamma delta"
        let chunks = TranscriptChunkPlanner.plan(t, maxTokensPerChunk: 100, overlapLines: 0, countTokens: count)
        #expect(chunks.contains { $0.text == giant })
        for w in ["alpha", "beta", "gamma", "delta"] { #expect(chunks.contains { $0.text.contains(w) }) }
        #expect(chunks.filter { count($0.text) > 100 }.map { $0.text } == [giant])
    }
}
