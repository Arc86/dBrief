import Foundation

public struct TranscriptWindow: Sendable, Equatable, Codable {
    public let index: Int
    public let start: Double
    public let end: Double
    public let text: String
    public init(index: Int, start: Double, end: Double, text: String) {
        self.index = index; self.start = start; self.end = end; self.text = text
    }
}

/// Pure building blocks for hybrid transcript retrieval (chat over long recordings).
public enum TranscriptRetrieval {
    public static func windows(_ turns: [TranscriptTurn], targetTokens: Int, overlapTurns: Int,
                               countTokens: (String) -> Int) -> [TranscriptWindow] {
        // Oversized single turns are split into sentence-packed pieces first.
        let units: [TranscriptTurn] = turns.flatMap { turn -> [TranscriptTurn] in
            let line = ChatTranscript.format([turn])
            guard countTokens(line) > targetTokens else { return [turn] }
            let prefixCost = countTokens(ChatTranscript.format([
                TranscriptTurn(start: turn.start, end: turn.end, speaker: turn.speaker, text: "")]))
            let pieces = TranscriptChunkPlanner.plan(turn.text, maxTokensPerChunk: max(8, targetTokens - prefixCost - 1),
                                                     overlapLines: 0, countTokens: countTokens)
            return pieces.map { TranscriptTurn(start: turn.start, end: turn.end, speaker: turn.speaker, text: $0.text) }
        }
        var out: [TranscriptWindow] = []
        var current: [TranscriptTurn] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(TranscriptWindow(index: out.count, start: first.start, end: last.end,
                                        text: ChatTranscript.format(current)))
        }
        for unit in units {
            let candidate = ChatTranscript.format(current + [unit])
            if !current.isEmpty, countTokens(candidate) > targetTokens {
                flush()
                let carry = Array(current.suffix(overlapTurns))
                current = countTokens(ChatTranscript.format(carry + [unit])) <= targetTokens ? carry : []
            }
            current.append(unit)
        }
        flush()
        return out
    }

    public static func tokenize(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    public static func bm25Ranking(query: String, windows: [TranscriptWindow]) -> [Int] {
        guard !windows.isEmpty else { return [] }
        let k1 = 1.2, b = 0.75
        let docs = windows.map { tokenize($0.text) }
        let avgLen = max(Double(docs.map(\.count).reduce(0, +)) / Double(docs.count), 1e-9)
        var df: [String: Int] = [:]
        for doc in docs { for term in Set(doc) { df[term, default: 0] += 1 } }
        let terms = Set(tokenize(query))
        let n = Double(docs.count)
        var scored: [(Int, Double)] = []
        for (i, doc) in docs.enumerated() {
            var tf: [String: Int] = [:]
            for t in doc where terms.contains(t) { tf[t, default: 0] += 1 }
            let lengthNorm: Double = 1 - b + b * Double(doc.count) / avgLen
            var score = 0.0
            for term in terms.sorted() {
                guard let count = tf[term] else { continue }
                let d = Double(df[term] ?? 0)
                let idf: Double = log(1 + (n - d + 0.5) / (d + 0.5))
                let f = Double(count)
                score += idf * f * (k1 + 1) / (f + k1 * lengthNorm)
            }
            scored.append((i, score))
        }
        return scored.filter { $0.1 > 0 }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            .map(\.0)
    }

    public static func cosineRanking(query: [Float], vectors: [[Float]]) -> [Int] {
        guard !vectors.isEmpty else { return [] }
        func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        let qn = dot(query, query).squareRoot()
        var scored: [(Int, Float)] = []
        for (i, v) in vectors.enumerated() {
            let denom = max(qn * dot(v, v).squareRoot(), 1e-9)
            scored.append((i, dot(query, v) / denom))
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.map(\.0)
    }

    public static func fuse(_ rankings: [[Int]], k: Double = 60) -> [Int] {
        var score: [Int: Double] = [:]
        for ranking in rankings {
            for (rank, id) in ranking.enumerated() { score[id, default: 0] += 1 / (k + Double(rank + 1)) }
        }
        return score.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    /// Transcript chat retrieval for one question, shared by the app and the eval:
    /// the top 30 BM25 windows, plus the top 30 by cosine when a query vector and
    /// document vectors exist, fused with RRF and assembled with one neighbour on
    /// each side within `budgetTokens`. With no vectors this is BM25 only.
    public static func hybridExcerpts(question: String, queryVector: [Float]?, windows: [TranscriptWindow],
                                      vectors: [[Float]], budgetTokens: Int,
                                      countTokens: (String) -> Int) -> String {
        var rankings = [Array(bm25Ranking(query: question, windows: windows).prefix(30))]
        if let queryVector, !vectors.isEmpty {
            rankings.insert(Array(cosineRanking(query: queryVector, vectors: vectors).prefix(30)), at: 0)
        }
        return excerpts(fuse(rankings), windows: windows, budgetTokens: budgetTokens, neighbors: 1,
                        countTokens: countTokens)
    }

    public static func excerpts(_ ranked: [Int], windows: [TranscriptWindow], budgetTokens: Int,
                                neighbors: Int, countTokens: (String) -> Int) -> String {
        var chosen = Set<Int>()
        var used = 0
        let radius = max(neighbors, 0)
        for hit in ranked {
            guard windows.indices.contains(hit) else { continue }
            func candidate(_ r: Int) -> (group: [Int], cost: Int) {
                let group = (hit - r...hit + r).filter { windows.indices.contains($0) && !chosen.contains($0) }
                return (group, group.reduce(0) { $0 + countTokens(windows[$1].text) + 2 })
            }
            var pick = candidate(radius)
            if used + pick.cost > budgetTokens, radius > 0 { pick = candidate(0) }
            guard !pick.group.isEmpty, used + pick.cost <= budgetTokens else { continue }
            chosen.formUnion(pick.group)
            used += pick.cost
        }
        var parts: [String] = []
        var previous: Int?
        for i in chosen.sorted() {
            if let previous, i != previous + 1 { parts.append("…") }
            parts.append(windows[i].text)
            previous = i
        }
        return parts.joined(separator: "\n")
    }
}
