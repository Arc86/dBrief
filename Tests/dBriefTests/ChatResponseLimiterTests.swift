import Testing
@testable import dBrief

@Suite("Chat response limits")
struct ChatResponseLimiterTests {
    @Test("Repeated lines are detected across arbitrary token boundaries")
    func repeatedLines() {
        var limiter = ChatResponseLimiter()
        let line = "- **20** – again referenced as a monetary value (£20).\n"
        var output = ""
        for character in String(repeating: line, count: 100) {
            output += limiter.append(String(character))
            if limiter.stopReason != nil { break }
        }
        #expect(limiter.stopReason == .repetition)
        #expect(output == String(repeating: line, count: 8))
    }

    @Test("Varied lists and short repeated formatting do not trigger repetition detection")
    func normalContent() {
        for text in [String(repeating: "---\n", count: 20), (1...20).map { "Result number \($0) is different.\n" }.joined()] {
            var limiter = ChatResponseLimiter()
            #expect(limiter.append(text) == text)
            #expect(limiter.stopReason == nil)
        }
    }

    @Test("Blank lines do not hide a repeated paragraph")
    func blankLines() {
        var limiter = ChatResponseLimiter()
        _ = limiter.append(String(repeating: "This same sentence keeps repeating.\n\n", count: 20))
        #expect(limiter.stopReason == .repetition)
    }

    @Test("A different line resets the repetition count")
    func reset() {
        var limiter = ChatResponseLimiter()
        let repeated = String(repeating: "This is a long repeated line.\n", count: 7)
        let text = repeated + "A different intervening sentence.\n" + repeated
        #expect(limiter.append(text) == text)
        #expect(limiter.stopReason == nil)
    }

    @Test("Oversized chunks are truncated and later chunks are ignored")
    func sizeLimit() {
        var limiter = ChatResponseLimiter()
        #expect(limiter.append(String(repeating: "a", count: 70_000)).count == 65_536)
        #expect(limiter.stopReason == .length)
        #expect(limiter.append("more output").isEmpty)
    }
}
