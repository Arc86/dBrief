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
    /// Most estimated tokens a live session may add to its KV cache after it was
    /// built before it is rebuilt from the bare-question history. Long-mode turns
    /// leave ~4K tokens of excerpts cached each. Only growth counts: a large
    /// full-transcript system prompt must not force a rebuild on every turn.
    public static let maxGrowthTokens = 32_000

    private let promptHash: Int
    private var userTurns: [String]
    private var turnCount: Int
    /// Estimated tokens (`ChatEngineProfile.estimateTokens`) recorded since the
    /// session was built; the system prompt and replayed history are not counted.
    public private(set) var grownTokens = 0

    public init(systemPrompt: String, history: [ChatTurnMessage]) {
        promptHash = systemPrompt.hashValue
        userTurns = history.filter { $0.role == .user }.map(\.content)
        turnCount = history.count
    }

    /// True when the live session already holds `systemPrompt` + `history` and can
    /// take a turn of `incomingTokens` without growing past `maxGrowthTokens`.
    public func canContinue(systemPrompt: String, history: [ChatTurnMessage], incomingTokens: Int = 0) -> Bool {
        systemPrompt.hashValue == promptHash
            && history.count == turnCount
            && history.filter { $0.role == .user }.map(\.content) == userTurns
            && !exceedsCap(incomingTokens: incomingTokens)
    }

    public func exceedsCap(incomingTokens: Int) -> Bool {
        grownTokens + incomingTokens > Self.maxGrowthTokens
    }

    /// Advances the key after a turn completed in the live session. `extraTokens`
    /// is what the turn carried besides the question (retrieved excerpts).
    public mutating func record(question: String, answer: String, extraTokens: Int = 0) {
        userTurns.append(question)
        turnCount += 2
        grownTokens += extraTokens + ChatEngineProfile.estimateTokens(question) + ChatEngineProfile.estimateTokens(answer)
    }
}
