import Foundation

/// Pure, view-agnostic regex search over the displayed transcript turns.
///
/// Each turn is identified by its `id` and searched by its rendered `text`, so
/// match offsets line up exactly with what `transcriptRow` displays. The query
/// is interpreted as a case-insensitive regular expression — a plain word is a
/// valid regex matching literally, so there is no separate "plain vs regex" mode.
enum TranscriptSearch {

    /// A single regex match within one turn's text, expressed in Character offsets
    /// so it maps cleanly onto `AttributedString` indices in the view layer.
    struct Match: Equatable {
        let turnId: UUID
        let location: Int     // Character offset of the match start within the turn text
        let length: Int       // Character length of the match
        let globalIndex: Int  // 0-based position in the flat, ordered match list
    }

    /// Outcome of a search: whether the pattern compiled, plus the ordered matches.
    struct Result: Equatable {
        var isValid: Bool
        var matches: [Match]

        static let empty = Result(isValid: true, matches: [])
    }

    /// Searches `turns` (id + displayed text) for `query`.
    ///
    /// Matches are ordered top-to-bottom across turns and left-to-right within
    /// each turn, with `globalIndex` numbering them 0..<count. An empty or
    /// whitespace-only query returns no matches but stays `isValid`. Leading/trailing whitespace in the query is ignored. A pattern
    /// that fails to compile returns `isValid == false` and no matches.
    /// Zero-length matches (e.g. `x*`) are skipped so highlighting can't loop.
    static func search(turns: [(id: UUID, text: String)], query: String) -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        guard let regex = try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive]) else {
            return Result(isValid: false, matches: [])
        }

        var matches: [Match] = []
        var globalIndex = 0
        for turn in turns {
            let text = turn.text
            if text.isEmpty { continue }
            let full = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, options: [], range: full) { result, _, _ in
                guard let result, result.range.length > 0,
                      let range = Range(result.range, in: text) else { return }
                let location = text.distance(from: text.startIndex, to: range.lowerBound)
                let length = text.distance(from: range.lowerBound, to: range.upperBound)
                matches.append(Match(turnId: turn.id, location: location, length: length, globalIndex: globalIndex))
                globalIndex += 1
            }
        }
        return Result(isValid: true, matches: matches)
    }

    /// What VoiceOver says for a search: "No results", "Invalid search pattern" or
    /// "Match 2 of 5: …the text around it…". `text` returns a turn's displayed text.
    static func announcement(for result: Result, current: Int, text: (UUID) -> String?) -> String {
        guard result.isValid else { return "Invalid search pattern" }
        guard !result.matches.isEmpty else { return "No results" }
        let index = min(max(current, 0), result.matches.count - 1)
        let match = result.matches[index]
        let position = "Match \(index + 1) of \(result.matches.count)"
        guard let turnText = text(match.turnId) else { return position }
        return "\(position): \(snippet(turnText, location: match.location, length: match.length))"
    }

    /// The match with up to `context` characters either side, marked "…" where cut.
    static func snippet(_ text: String, location: Int, length: Int, context: Int = 30) -> String {
        let characters = Array(text)
        let matchEnd = min(location + length, characters.count)
        var start = max(0, min(location - context, characters.count))
        var end = min(characters.count, max(location + length + context, start))
        // Cut at word boundaries, never through the match.
        if start > 0, !characters[start - 1].isWhitespace,
           let space = characters[start..<max(start, location)].firstIndex(where: \.isWhitespace) {
            start = space + 1
        }
        if end < characters.count, !characters[end].isWhitespace,
           let space = characters[min(matchEnd, end)..<end].lastIndex(where: \.isWhitespace) {
            end = space
        }
        let body = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > 0 ? "…" : "") + body + (end < characters.count ? "…" : "")
    }
}
