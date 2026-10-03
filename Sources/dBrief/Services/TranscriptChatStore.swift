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
    private enum Key: Hashable { case recording(UUID), legacy(URL) }
    private var sessions: [Key: TranscriptChatService] = [:]
    private var aliases: [URL: Key] = [:]
    /// Most recently used last. The session for the open transcript is always
    /// the most recent (every `session(for:)` access touches it), so eviction
    /// never removes it.
    private var accessOrder: [Key] = []
    private let maxSessions = 5

    func session(for url: URL) -> TranscriptChatService? {
        let key = aliases[url.standardizedFileURL] ?? .legacy(url.standardizedFileURL)
        guard let service = sessions[key] else { return nil }
        touch(key)
        return service
    }

    func set(_ service: TranscriptChatService, for url: URL) {
        let key = Key.legacy(url.standardizedFileURL)
        sessions[key] = service; aliases[url.standardizedFileURL] = key
        touch(key)
        evictIfNeeded()
    }

    func remove(for url: URL) {
        remove(aliases[url.standardizedFileURL] ?? .legacy(url.standardizedFileURL))
    }

    func hasMessages(for url: URL) -> Bool {
        !(session(for: url)?.messages.isEmpty ?? true)
    }

    func session(for recordingID: UUID, url: URL) -> TranscriptChatService? {
        let key = Key.recording(recordingID)
        if let service = sessions[key] { addAlias(url, for: key); touch(key); return service }
        let legacy = Key.legacy(url.standardizedFileURL)
        guard let service = sessions[legacy], service.recordingIdentity == recordingID else { return nil }
        remove(legacy); set(service, for: recordingID, url: url); return service
    }

    func set(_ service: TranscriptChatService, for recordingID: UUID, url: URL) {
        guard service.recordingIdentity == recordingID else { return }
        let key = Key.recording(recordingID)
        guard sessions[key] == nil || sessions[key] === service else { return }
        sessions[key] = service; addAlias(url, for: key); touch(key); evictIfNeeded()
    }
    func remove(for recordingID: UUID) { remove(.recording(recordingID)) }

    private func addAlias(_ url: URL, for key: Key) {
        let url = url.standardizedFileURL
        guard aliases[url] != key else { return }
        // At most the original capture and current finalized URL per session.
        let existing = aliases.filter { $0.value == key }.map(\.key)
        if existing.count >= 2 { for old in existing { aliases[old] = nil } }
        aliases[url] = key
    }
    private func remove(_ key: Key) {
        sessions[key] = nil; accessOrder.removeAll { $0 == key }
        aliases = aliases.filter { $0.value != key }
    }

    /// Flush every session's pending (debounced) save to disk. Called on app
    /// termination so an exchange sent within the debounce window isn't lost.
    func flushAll() async {
        for session in sessions.values {
            await session.flushPendingSave()
        }
    }

    private func touch(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    /// Drop least-recently-used sessions beyond the cap, flushing any pending
    /// save first. Only sessions whose history is backed by a sidecar are
    /// evictable — an evicted session's messages must be recoverable from disk
    /// on reopen. A mid-stream session, and a live (not-yet-persisted, e.g.
    /// in-progress recording) session, are therefore never evicted; the latter's
    /// history exists only in memory and would otherwise be silently lost.
    private func evictIfNeeded() {
        guard sessions.count > maxSessions else { return }
        for key in accessOrder.dropLast() {
            guard sessions.count > maxSessions else { return }
            guard let service = sessions[key], service.canEvictFromCache else { continue }
            remove(key)
        }
    }
}
