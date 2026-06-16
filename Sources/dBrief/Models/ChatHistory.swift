import Foundation

/// Transcript chat conversation persisted alongside a recording as
/// `<base>.chat.json`. Mirrors the `RecordingInsights` / `RichTranscript`
/// sidecar pattern so chat history survives an app restart (it was previously
/// kept in-memory only by `TranscriptChatStore`). Privacy-wise it follows the
/// same on-disk location and retention policy as transcripts/insights.
struct ChatHistory: Codable, Sendable, Equatable {
    var version: Int
    var messages: [ChatMessage]
    /// The AI engine that produced the conversation, for display/debugging.
    /// Optional so older sidecars (and the common case) decode cleanly.
    var engine: String?

    init(version: Int = 1, messages: [ChatMessage], engine: String? = nil) {
        self.version = version
        self.messages = messages
        self.engine = engine
    }

    var isEmpty: Bool { messages.isEmpty }
}
