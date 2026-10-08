import Foundation

public struct TranscriptChunk: Sendable, Equatable {
    public let index: Int
    public let total: Int
    public let text: String
    public init(index: Int, total: Int, text: String) {
        self.index = index; self.total = total; self.text = text
    }
}

/// Splits a transcript into token-bounded parts for map-reduce analysis. Prefers
/// speaker-turn (line) boundaries, then sentences, then words, so no text is ever
/// dropped. Consecutive parts share `overlapLines` units for continuity. Pure.
public enum TranscriptChunkPlanner {
    public static func plan(_ transcript: String, maxTokensPerChunk: Int, overlapLines: Int,
                            countTokens: (String) -> Int) -> [TranscriptChunk] {
        guard countTokens(transcript) > maxTokensPerChunk else {
            return [TranscriptChunk(index: 1, total: 1, text: transcript)]
        }
        let units = transcript.split(separator: "\n", omittingEmptySubsequences: true)
            .flatMap { fit(String($0), budget: maxTokensPerChunk, countTokens: countTokens) }
        let costs = units.map { countTokens($0) + 1 } // +1 for the joining newline

        var groups: [[Int]] = []
        var current: [Int] = []
        var used = 0
        for i in units.indices {
            if !current.isEmpty, used + costs[i] > maxTokensPerChunk {
                groups.append(current)
                // Carry overlap only while it leaves room for new content.
                let carry = Array(current.suffix(overlapLines))
                let carryCost = carry.reduce(0) { $0 + costs[$1] }
                current = carryCost + costs[i] <= maxTokensPerChunk / 2 ? carry : []
                used = current.reduce(0) { $0 + costs[$1] }
            }
            current.append(i)
            used += costs[i]
        }
        if !current.isEmpty { groups.append(current) }
        return groups.enumerated().map { offset, group in
            TranscriptChunk(index: offset + 1, total: groups.count,
                            text: group.map { units[$0] }.joined(separator: "\n"))
        }
    }

    /// Returns `line` unchanged when it fits, else sentence pieces, else word runs.
    private static func fit(_ line: String, budget: Int, countTokens: (String) -> Int) -> [String] {
        if countTokens(line) < budget { return [line] }
        let sentences = line.split(separator: " ", omittingEmptySubsequences: true)
            .reduce(into: [String]()) { acc, word in
                if let last = acc.last, !(last.hasSuffix(".") || last.hasSuffix("!") || last.hasSuffix("?")) {
                    acc[acc.count - 1] = last + " " + word
                } else { acc.append(String(word)) }
            }
        if sentences.count > 1, sentences.allSatisfy({ countTokens($0) < budget }) {
            return pack(sentences, budget: budget, countTokens: countTokens)
        }
        let words = line.split(separator: " ").map(String.init)
        return pack(words, budget: budget, countTokens: countTokens)
    }

    /// Greedily joins pieces with spaces into runs below `budget`. A single piece that
    /// alone exceeds `budget` (e.g. one enormous word) cannot be split further; it is
    /// kept whole as its own run rather than dropped or truncated, so it may exceed the budget.
    private static func pack(_ pieces: [String], budget: Int, countTokens: (String) -> Int) -> [String] {
        var out: [String] = []
        var run = ""
        for piece in pieces {
            let candidate = run.isEmpty ? piece : run + " " + piece
            if !run.isEmpty, countTokens(candidate) >= budget { out.append(run); run = piece }
            else { run = candidate }
        }
        if !run.isEmpty { out.append(run) }
        return out
    }
}
