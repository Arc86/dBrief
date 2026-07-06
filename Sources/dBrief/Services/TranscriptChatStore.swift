import Foundation

/// Keeps chat sessions alive across recording switches. The transcript detail
/// view is recreated whenever the selected recording changes, so the chat
/// service can't live in that view's `@State`. This store caches one session
/// per recording (keyed by audio file URL), keeping only the most recently
/// used few — each session holds transcript text, message history, and a
/// prewarmed model handle, so an unbounded cache grew for the whole app run.
@MainActor
@Observable
final class TranscriptChatStore {
    private var sessions: [URL: TranscriptChatService] = [:]
    /// Most recently used last. The session for the open transcript is always
    /// the most recent (every `session(for:)` access touches it), so eviction
    /// never removes it.
    private var accessOrder: [URL] = []
    private let maxSessions = 5

    func session(for url: URL) -> TranscriptChatService? {
        guard let service = sessions[url] else { return nil }
        touch(url)
        return service
    }

    func set(_ service: TranscriptChatService, for url: URL) {
        sessions[url] = service
        touch(url)
        evictIfNeeded()
    }

    func remove(for url: URL) {
        sessions[url] = nil
        accessOrder.removeAll { $0 == url }
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

    private func touch(_ url: URL) {
        accessOrder.removeAll { $0 == url }
        accessOrder.append(url)
    }

    /// Drop least-recently-used sessions beyond the cap, flushing any pending
    /// save first. A session that is mid-stream is never evicted (persisted
    /// history survives eviction either way — it reloads from the sidecar).
    private func evictIfNeeded() {
        guard sessions.count > maxSessions else { return }
        for url in accessOrder.dropLast() {
            guard sessions.count > maxSessions else { return }
            guard let service = sessions[url], !service.isStreaming else { continue }
            sessions[url] = nil
            accessOrder.removeAll { $0 == url }
            Task { await service.flushPendingSave() }
        }
    }
}
