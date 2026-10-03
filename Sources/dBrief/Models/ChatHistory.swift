import Foundation
import dBriefWire

/// Transcript chat conversation persisted alongside a recording as
/// `<base>.chat.json`. Mirrors the `RecordingInsights` / `RichTranscript`
/// sidecar pattern so chat history survives an app restart (it was previously
/// kept in-memory only by `TranscriptChatStore`). Privacy-wise it follows the
/// same on-disk location and retention policy as transcripts/insights.
struct ChatHistory: Codable, Sendable, Equatable {
    static let currentVersion = 2
    var version: Int
    var messages: [ChatMessage]
    /// The AI engine that produced the conversation, for display/debugging.
    /// Optional so older sidecars (and the common case) decode cleanly.
    var engine: String?
    /// Absent on legacy histories. A filename alone never establishes ownership.
    var identity: LiveSessionIdentity?
    var revision: UInt64?
    var bindingGeneration: UUID?

    init(version: Int = currentVersion, messages: [ChatMessage], engine: String? = nil,
         identity: LiveSessionIdentity? = nil, revision: UInt64? = nil, bindingGeneration: UUID? = nil) {
        self.version = version
        self.messages = messages
        self.engine = engine
        self.identity = identity; self.revision = revision; self.bindingGeneration = bindingGeneration
    }

    var isEmpty: Bool { messages.isEmpty }

    func validateVersion() throws {
        guard (1...Self.currentVersion).contains(version) else { throw ChatStoreError.unsupportedVersion }
    }

    var interruptedAfterRestart: Self {
        var copy = self
        for index in copy.messages.indices where copy.messages[index].role == .assistant && copy.messages[index].outcome == .streaming {
            copy.messages[index].outcome = .interrupted
        }
        return copy
    }
}
