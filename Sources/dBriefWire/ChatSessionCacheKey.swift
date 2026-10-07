import Foundation

/// One earlier chat message, sent with `MLRequest.chatTurn`. User messages are
/// the bare questions (no retrieved context); assistant messages are the replies.
public struct ChatTurnMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) { self.role = role; self.content = content }
}

/// Decides whether a live chat session (whose KV cache already holds the system
/// prompt + earlier turns) can answer the next question without re-prefilling.
/// Keyed on the system prompt and the *user* turns only: assistant text may be
/// trimmed by the app after streaming, which does not invalidate the cache.
///
/// `hashValue` is per-process; that is fine because the key lives only in the
/// helper's memory and is never persisted.
public struct ChatSessionCacheKey: Sendable, Equatable {
    /// Largest estimated KV cache a live session may grow to before it is rebuilt
    /// from the bare-question history. Long-mode turns carry ~6K tokens of excerpts
    /// that stay cached, so without a cap the cache grows toward Gemma's window.
    public static let maxCachedTokens = 40_000

    private let promptHash: Int
    private var userTurns: [String]
    private var turnCount: Int
    /// Estimated tokens the session's KV cache holds (`ChatEngineProfile.estimateTokens`).
    public private(set) var cachedTokens: Int

    public init(systemPrompt: String, history: [ChatTurnMessage]) {
        promptHash = systemPrompt.hashValue
        userTurns = history.filter { $0.role == .user }.map(\.content)
        turnCount = history.count
        cachedTokens = history.reduce(ChatEngineProfile.estimateTokens(systemPrompt)) {
            $0 + ChatEngineProfile.estimateTokens($1.content)
        }
    }

    /// True when the live session already holds `systemPrompt` + `history` and can
    /// take a turn of `incomingTokens` without exceeding `maxCachedTokens`.
    public func canContinue(systemPrompt: String, history: [ChatTurnMessage], incomingTokens: Int = 0) -> Bool {
        systemPrompt.hashValue == promptHash
            && history.count == turnCount
            && history.filter { $0.role == .user }.map(\.content) == userTurns
            && !exceedsCap(incomingTokens: incomingTokens)
    }

    public func exceedsCap(incomingTokens: Int) -> Bool {
        cachedTokens + incomingTokens > Self.maxCachedTokens
    }

    /// Advances the key after a turn completed in the live session. `extraTokens`
    /// is what the turn carried besides the question (retrieved excerpts).
    public mutating func record(question: String, answer: String, extraTokens: Int = 0) {
        userTurns.append(question)
        turnCount += 2
        cachedTokens += extraTokens + ChatEngineProfile.estimateTokens(question) + ChatEngineProfile.estimateTokens(answer)
    }
}
