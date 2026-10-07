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
            let pieces = TranscriptChunkPlanner.plan(turn.text, maxTokensPerChunk: max(16, targetTokens - 16),
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
            for (term, count) in tf {
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

    public static func excerpts(_ ranked: [Int], windows: [TranscriptWindow], budgetTokens: Int,
                                neighbors: Int, countTokens: (String) -> Int) -> String {
        var chosen = Set<Int>()
        var used = 0
        let radius = max(neighbors, 0)
        for hit in ranked {
            let group = (hit - radius...hit + radius).filter { windows.indices.contains($0) && !chosen.contains($0) }
            let cost = group.reduce(0) { $0 + countTokens(windows[$1].text) + 2 }
            guard !group.isEmpty, used + cost <= budgetTokens else { continue }
            chosen.formUnion(group)
            used += cost
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
