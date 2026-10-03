import Foundation
import dBriefWire

enum ChatStreamEndError: Error, Equatable, LocalizedError {
    case truncated, unconfirmed
    var errorDescription: String? {
        switch self {
        case .truncated: "The provider reached its output limit. The answer is incomplete; try a narrower question."
        case .unconfirmed: "Answer preserved; the provider did not confirm complete generation."
        }
    }
    static func classify(_ error: any Error) -> Self? {
        if let value = error as? Self { return value }
        if let wire = error as? WireError {
            switch wire.kind { case .chatTruncated: return .truncated; case .chatUnconfirmed: return .unconfirmed; default: break }
        }
        return nil
    }
}

/// Parse terminal facts independently of network EOF. No tools are dispatched.
struct ChatSSEParser {
    let anthropic: Bool
    private var stopReason: String?
    private var messageStopped = false
    init(anthropic: Bool) { self.anthropic = anthropic }

    mutating func consume(_ payload: String) throws -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatStreamEndError.unconfirmed }
        if object["error"] != nil || object["type"] as? String == "error" {
            throw NSError(domain: "ChatProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "The provider reported a streaming error. Try again."])
        }
        if anthropic {
            if let type = object["type"], !(type is String) { throw ChatStreamEndError.unconfirmed }
            switch object["type"] as? String {
            case "message_delta":
                guard !messageStopped else { throw ChatStreamEndError.unconfirmed }
                guard let delta = object["delta"] as? [String: Any] else { throw ChatStreamEndError.unconfirmed }
                if let reason = delta["stop_reason"], !(reason is NSNull) {
                    guard let reason = reason as? String else { throw ChatStreamEndError.unconfirmed }
                    try recordStop(reason)
                }
            case "message_stop": messageStopped = true
            case "content_block_delta":
                guard stopReason == nil, !messageStopped else { throw ChatStreamEndError.unconfirmed }
                guard let delta = object["delta"] as? [String: Any] else { throw ChatStreamEndError.unconfirmed }
                if let text = delta["text"] {
                    guard delta["type"] as? String == "text_delta", let text = text as? String else {
                        throw ChatStreamEndError.unconfirmed
                    }
                    return text
                }
                if delta["type"] as? String == "text_delta" { throw ChatStreamEndError.unconfirmed }
                // Known thinking/signature/tool-json metadata does not contain answer text.
                guard ["thinking_delta", "signature_delta", "input_json_delta"].contains(delta["type"] as? String ?? "") else {
                    throw ChatStreamEndError.unconfirmed
                }
            default: break
            }
        } else {
            guard let rawChoices = object["choices"] else { return nil }
            guard let choices = rawChoices as? [[String: Any]], choices.count <= 1 else { throw ChatStreamEndError.unconfirmed }
            guard let choice = choices.first else { return nil }
            guard choice["index"] == nil || choice["index"] as? Int == 0 else { throw ChatStreamEndError.unconfirmed }
            let delta: [String: Any]
            if let raw = choice["delta"] {
                guard let object = raw as? [String: Any] else { throw ChatStreamEndError.unconfirmed }
                delta = object
            } else { delta = [:] }
            if delta["tool_calls"] != nil || delta["function_call"] != nil { throw ChatStreamEndError.unconfirmed }
            let text: String?
            if let raw = delta["content"], !(raw is NSNull) {
                guard let content = raw as? String else { throw ChatStreamEndError.unconfirmed }
                text = content
            } else { text = nil }
            if let text, !text.isEmpty, stopReason != nil { throw ChatStreamEndError.unconfirmed }
            if let raw = choice["finish_reason"], !(raw is NSNull) {
                guard let reason = raw as? String else { throw ChatStreamEndError.unconfirmed }
                try recordStop(reason)
            }
            return text
        }
        return nil
    }

    private mutating func recordStop(_ reason: String) throws {
        if let stopReason, stopReason != reason { throw ChatStreamEndError.unconfirmed }
        stopReason = reason
    }

    func finish() throws {
        guard let stopReason, !anthropic || messageStopped else { throw ChatStreamEndError.unconfirmed }
        if stopReason == "length" || stopReason == "max_tokens" { throw ChatStreamEndError.truncated }
        guard anthropic ? ["end_turn", "stop_sequence"].contains(stopReason) : stopReason == "stop" else {
            throw ChatStreamEndError.unconfirmed
        }
    }
}
