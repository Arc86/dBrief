import Foundation

/// A folder dBrief monitors for dropped-in audio files. When a new, fully-written audio
/// file appears, it is automatically transcribed, analyzed, and exported via the normal
/// pipeline (the file is imported into the recordings folder; the original is left in place).
///
/// The folder is persisted as a security-scoped bookmark so access survives relaunch.
struct WatchedFolder: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// Security-scoped bookmark for the folder.
    var bookmark: Data
    /// Last-known filesystem path, used for display and as the scanner's stable folder key.
    var displayPath: String
    /// When false the folder is kept in the list but not scanned.
    var isEnabled: Bool

    init(id: UUID = UUID(), bookmark: Data, displayPath: String, isEnabled: Bool = true) {
        self.id = id
        self.bookmark = bookmark
        self.displayPath = displayPath
        self.isEnabled = isEnabled
    }

    /// Resolve the bookmark to a URL and begin security-scoped access. Callers are
    /// responsible for `stopAccessingSecurityScopedResource()` when done. Returns `nil`
    /// if the bookmark is stale or unresolvable.
    func resolveURL() -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    /// Build a watched folder from a freshly picked URL, capturing its security-scoped bookmark.
    static func make(from url: URL) -> WatchedFolder? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }
        return WatchedFolder(bookmark: data, displayPath: url.path)
    }
}
