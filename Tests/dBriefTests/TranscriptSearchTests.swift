import Foundation
@testable import dBrief
import Testing

struct TranscriptSearchTests {
    private func turn(_ text: String, _ id: UUID = UUID()) -> (id: UUID, text: String) {
        (id: id, text: text)
    }

    private func substring(_ text: String, _ m: TranscriptSearch.Match) -> String {
        let chars = Array(text)
        return String(chars[m.location ..< (m.location + m.length)])
    }

    @Test("empty query yields no matches and is valid")
    func emptyQuery() {
        let result = TranscriptSearch.search(turns: [turn("Hello world")], query: "")
        #expect(result.isValid)
        #expect(result.matches.isEmpty)
    }

    @Test("whitespace-only query yields no matches and is valid")
    func whitespaceQuery() {
        let result = TranscriptSearch.search(turns: [turn("Hello world")], query: "   ")
        #expect(result.isValid)
        #expect(result.matches.isEmpty)
    }

    @Test("literal substring matches every occurrence in a turn")
    func multipleOccurrences() {
        let t = turn("the budget is the budget plan")
        let result = TranscriptSearch.search(turns: [t], query: "budget")
        #expect(result.isValid)
        #expect(result.matches.count == 2)
        #expect(result.matches[0].location == 4)
        #expect(result.matches[0].length == 6)
        #expect(substring(t.text, result.matches[0]) == "budget")
        #expect(substring(t.text, result.matches[1]) == "budget")
        #expect(result.matches.map(\.globalIndex) == [0, 1])
    }

    @Test("matches are ordered top-to-bottom across turns with sequential globalIndex")
    func orderingAcrossTurns() {
        let a = turn("alpha cat", UUID())
        let b = turn("cat beta cat", UUID())
        let result = TranscriptSearch.search(turns: [a, b], query: "cat")
        #expect(result.matches.count == 3)
        #expect(result.matches[0].turnId == a.id)
        #expect(result.matches[1].turnId == b.id)
        #expect(result.matches[2].turnId == b.id)
        #expect(result.matches.map(\.globalIndex) == [0, 1, 2])
    }

    @Test("search is case-insensitive")
    func caseInsensitive() {
        let result = TranscriptSearch.search(turns: [turn("Budget review")], query: "budget")
        #expect(result.matches.count == 1)
    }

    @Test("regex metacharacters work")
    func regexPattern() {
        let t = turn("cat category scatter")
        // \bcat\b should match only the standalone word "cat"
        let result = TranscriptSearch.search(turns: [t], query: "\\bcat\\b")
        #expect(result.matches.count == 1)
        #expect(substring(t.text, result.matches[0]) == "cat")
    }

    @Test("invalid regex is reported and yields no matches")
    func invalidRegex() {
        let result = TranscriptSearch.search(turns: [turn("Hello (world")], query: "(")
        #expect(result.isValid == false)
        #expect(result.matches.isEmpty)
    }

    @Test("no-match query yields empty valid result")
    func noMatch() {
        let result = TranscriptSearch.search(turns: [turn("Hello world")], query: "zzz")
        #expect(result.isValid)
        #expect(result.matches.isEmpty)
    }

    @Test("zero-length regex matches are ignored")
    func zeroLengthMatchesIgnored() {
        let result = TranscriptSearch.search(turns: [turn("Hello world")], query: "x*")
        #expect(result.matches.isEmpty)
    }
}
