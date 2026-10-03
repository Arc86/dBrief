import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Chat provider terminal outcomes")
struct ChatStreamCompletionTests {
    @Test(arguments: ["thinking_delta", "signature_delta", "input_json_delta", "unknown", "missing", "nonstring"])
    func anthropicMetadataCannotBecomeCompletedAnswerText(type: String) throws {
        var delta: [String: Any] = ["text": "Hidden metadata"]
        if type == "nonstring" { delta["type"] = 42 }
        else if type != "missing" { delta["type"] = type }
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: [
            "type": "content_block_delta", "delta": delta,
        ]), as: UTF8.self)
        var parser = ChatSSEParser(anthropic: true)
        #expect(throws: ChatStreamEndError.unconfirmed) {
            _ = try parser.consume(payload)
            _ = try parser.consume(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#)
            _ = try parser.consume(#"{"type":"message_stop"}"#)
            try parser.finish()
        }
    }

    @Test(arguments: ["thinking_delta", "signature_delta", "input_json_delta"])
    func recognizedAnthropicMetadataWithoutAnswerTextIsIgnored(type: String) throws {
        var parser = ChatSSEParser(anthropic: true)
        #expect(try parser.consume("{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"\(type)\"}}") == nil)
        #expect(try parser.consume(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Answer"}}"#) == "Answer")
        _ = try parser.consume(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#)
        _ = try parser.consume(#"{"type":"message_stop"}"#)
        try parser.finish()
    }

    @Test func malformedDataAndContradictoryTerminalsCannotBecomeCompleted() throws {
        var malformed = ChatSSEParser(anthropic: false)
        #expect(throws: ChatStreamEndError.unconfirmed) {
            try malformed.consume(#"{"choices":[{"delta":{"content":"Lost"#)
        }
        var contradiction = ChatSSEParser(anthropic: false)
        _ = try contradiction.consume(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#)
        #expect(throws: ChatStreamEndError.unconfirmed) {
            try contradiction.consume(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        }
    }
    @Test(arguments: [false, true]) func malformedRecognizedTextCannotDisappear(anthropic: Bool) {
        var parser = ChatSSEParser(anthropic: anthropic)
        let payload = anthropic
            ? #"{"type":"content_block_delta","delta":{"type":"text_delta","text":["Lost"]}}"#
            : #"{"choices":[{"delta":{"content":["Lost"]}}]}"#
        #expect(throws: ChatStreamEndError.unconfirmed) { try parser.consume(payload) }
    }
    @Test func EOFOrDoneWithoutFinishIsUnconfirmed() throws {
        var parser = ChatSSEParser(anthropic: false)
        #expect(try parser.consume("{\"choices\":[{\"delta\":{\"content\":\"Partial\"}}]}") == "Partial")
        #expect(throws: ChatStreamEndError.unconfirmed) { try parser.finish() }
    }
    @Test func openAIStopAndLengthHaveDifferentOutcomes() throws {
        var parser = ChatSSEParser(anthropic: false)
        _ = try parser.consume("{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}")
        try parser.finish()
        var limited = ChatSSEParser(anthropic: false)
        _ = try limited.consume("{\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}")
        #expect(throws: ChatStreamEndError.truncated) { try limited.finish() }
    }
    @Test func anthropicRequiresStopReasonAndMessageStopAndPropagatesError() throws {
        var parser = ChatSSEParser(anthropic: true)
        _ = try parser.consume("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}")
        #expect(throws: ChatStreamEndError.unconfirmed) { try parser.finish() }
        _ = try parser.consume("{\"type\":\"message_stop\"}")
        try parser.finish()
        var failed = ChatSSEParser(anthropic: true)
        #expect(throws: (any Error).self) { try failed.consume("{\"type\":\"error\",\"error\":{\"message\":\"fixture failed\"}}") }
    }
}
