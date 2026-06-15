import Foundation

/// A point-in-time view of an audio file in a watched folder. Identity is the absolute
/// path; `size` drives the "is the file done being written?" stability check.
struct WatchedFileSnapshot: Equatable, Sendable {
    let path: String
    let size: Int64
}

/// Pure, side-effect-light helpers for the watched-folders feature. The filesystem read in
/// `audioFiles(in:)` is the only impure part; the decision logic in `newlyStableFiles(...)`
/// is fully pure so it can be unit-tested without touching disk.
enum WatchedFolderScanner {

    /// Audio extensions a watched folder will pick up. Superset of the recording formats —
    /// watched folders are commonly fed arbitrary audio (podcasts, voice memos, exports).
    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "flac", "aac", "ogg", "opus", "m4b", "aiff", "aif", "caf", "wma",
    ]

    /// Enumerate the audio files directly inside `folder` (non-recursive). Returns a snapshot
    /// per file. Hidden files and dBrief's own temporary/sidecar files are ignored.
    static func audioFiles(in folder: URL, fileManager: FileManager = .default) -> [WatchedFileSnapshot] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        return entries.compactMap { url -> WatchedFileSnapshot? in
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }
            let size = Int64(values?.fileSize ?? 0)
            return WatchedFileSnapshot(path: url.path, size: size)
        }
    }

    /// Files that are ready to process: present in BOTH the current and previous scans with an
    /// identical, non-zero size (so a file still being written isn't grabbed mid-copy), and not
    /// already in `processed`.
    static func newlyStableFiles(
        current: [WatchedFileSnapshot],
        previous: [WatchedFileSnapshot],
        processed: Set<String>
    ) -> [WatchedFileSnapshot] {
        let previousByPath = Dictionary(previous.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return current.filter { snap in
            guard snap.size > 0, !processed.contains(snap.path) else { return false }
            guard let prev = previousByPath[snap.path] else { return false }
            return prev.size == snap.size
        }
    }
}
