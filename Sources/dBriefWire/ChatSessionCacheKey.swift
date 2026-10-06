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
    private let promptHash: Int
    private var userTurns: [String]
    private var turnCount: Int

    public init(systemPrompt: String, history: [ChatTurnMessage]) {
        promptHash = systemPrompt.hashValue
        userTurns = history.filter { $0.role == .user }.map(\.content)
        turnCount = history.count
    }

    public func canContinue(systemPrompt: String, history: [ChatTurnMessage]) -> Bool {
        systemPrompt.hashValue == promptHash
            && history.count == turnCount
            && history.filter { $0.role == .user }.map(\.content) == userTurns
    }

    /// Advances the key after a turn completed in the live session.
    public mutating func record(question: String, answer: String) {
        userTurns.append(question)
        turnCount += 2
    }
}
