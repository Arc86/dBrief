import Foundation
import Testing
@testable import dBrief

@Suite("AIService remote-response parsing")
struct AIServiceParsingTests {
    // MARK: - Reasoning / think-block stripping

    @Test("Strips a complete <think> block from content")
    func stripsThinkBlock() {
        let raw = "<think>Let me reason about this in detail…</think>\n\nThe meeting covered Q3 planning."
        #expect(AIService.cleanContent(raw) == "The meeting covered Q3 planning.")
    }

    @Test("Strips multiple think blocks")
    func stripsMultipleThinkBlocks() {
        let raw = "<think>a</think>Hello <think>b</think>world"
        #expect(AIService.cleanContent(raw) == "Hello world")
    }

    @Test("Leaves plain content untouched")
    func leavesPlainContent() {
        #expect(AIService.cleanContent("Just a summary.") == "Just a summary.")
    }

    // MARK: - Tags JSON parsing (the minimax/gemma failure)

    @Test("Parses tags JSON wrapped in a think block and code fence")
    func parsesTagsWithThinkAndFence() {
        let response = """
        <think>The user wants tags. I'll pick three.</think>
        Here is the result:
        ```json
        {"tags": ["planning", "q3", "budget"], "sentiment": "positive"}
        ```
        """
        let result = AIService.parseTags(from: response)
        #expect(result.tags == ["planning", "q3", "budget"])
        #expect(result.sentiment == "positive")
    }

    @Test("Parses bare tags JSON object")
    func parsesBareTagsJSON() {
        let result = AIService.parseTags(from: #"{"tags": ["x"], "sentiment": "negative"}"#)
        #expect(result.tags == ["x"])
        #expect(result.sentiment == "negative")
    }

    @Test("Falls back to neutral when no JSON present")
    func tagsFallbackNeutral() {
        let result = AIService.parseTags(from: "I could not produce tags.")
        #expect(result.tags.isEmpty)
        #expect(result.sentiment == "neutral")
    }

    // MARK: - Action item parsing

    @Test("Extracts dash, asterisk, bullet and numbered action items after a think block")
    func parsesActionItems() {
        let response = """
        <think>reasoning here</think>
        - Email the deck to Sam
        * Book the room
        • Confirm budget
        1. Send invites
        """
        let items = AIService.parseActionItems(from: response)
        #expect(items == ["Email the deck to Sam", "Book the room", "Confirm budget", "Send invites"])
    }

    // MARK: - Context-window overflow detection

    @Test("Detects llama.cpp context overflow error")
    func detectsLlamaCppOverflow() {
        let body = #"{"error":{"code":500,"message":"request (14919 tokens) exceeds the available context size (8192 tokens), try increasing it","type":"server_error"}}"#
        #expect(AIService.isContextOverflow(body))
    }

    @Test("Detects vLLM / OpenAI context-length error")
    func detectsOpenAIOverflow() {
        let body = #"{"error":{"message":"This model's maximum context length is 8192 tokens. However, you requested 14919 tokens.","code":"context_length_exceeded"}}"#
        #expect(AIService.isContextOverflow(body))
    }

    @Test("Does not flag unrelated server errors as overflow")
    func ignoresUnrelatedErrors() {
        #expect(!AIService.isContextOverflow(#"{"error":"model not found"}"#))
        #expect(!AIService.isContextOverflow("Internal Server Error"))
    }
}
