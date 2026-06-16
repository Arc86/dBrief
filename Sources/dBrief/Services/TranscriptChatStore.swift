import Foundation

/// Keeps chat sessions alive across recording switches. The transcript detail
/// view is recreated whenever the selected recording changes, so the chat
/// service can't live in that view's `@State`. This store caches one session
/// per recording (keyed by audio file URL) for the lifetime of the app run.
@MainActor
@Observable
final class TranscriptChatStore {
    private var sessions: [URL: TranscriptChatService] = [:]

    func session(for url: URL) -> TranscriptChatService? {
        sessions[url]
    }

    func set(_ service: TranscriptChatService, for url: URL) {
        sessions[url] = service
    }

    func remove(for url: URL) {
        sessions[url] = nil
    }

    func hasMessages(for url: URL) -> Bool {
        !(sessions[url]?.messages.isEmpty ?? true)
    }

    /// Flush every session's pending (debounced) save to disk. Called on app
    /// termination so an exchange sent within the debounce window isn't lost.
    func flushAll() async {
        for session in sessions.values {
            await session.flushPendingSave()
        }
    }
}
