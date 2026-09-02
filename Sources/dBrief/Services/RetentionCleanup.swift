import Foundation
import os
import dBriefWire

private let log = Logger.recording

/// What kind of artifacts a retention sweep targets.
enum RetentionCategory: Sendable, Hashable, CaseIterable {
    /// Audio masters/segments and their recording metadata sidecars.
    case recordings
    /// Transcript, rich-transcript, AI-insights, and Markdown note files.
    case transcripts

    var displayName: String {
        switch self {
        case .recordings: "recordings"
        case .transcripts: "transcripts"
        }
    }
}

/// Outcome of a single retention sweep.
struct RetentionCleanupResult: Sendable {
    var filesDeleted: Int = 0
    var bytesFreed: Int64 = 0

    /// One-line, user-facing summary for the Settings UI.
    var summary: String {
        guard filesDeleted > 0 else { return "Nothing to delete." }
        let size = ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
        let noun = filesDeleted == 1 ? "file" : "files"
        return "Deleted \(filesDeleted) \(noun) (\(size))."
    }
}

/// Pure cadence decision used by the long-running menu-bar scheduler. Keeping the
/// date arithmetic separate makes clock-edge behavior deterministic in tests.
enum RetentionSchedule {
    static let dailyInterval: TimeInterval = 24 * 60 * 60

    static func isDue(
        lastRun: Date?,
        now: Date = Date(),
        interval: TimeInterval = dailyInterval
    ) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= interval
    }
}

/// Age-based cleanup of recordings and transcripts in the output folders.
///
/// Stateless on purpose: callers (the launch sweep in `AppContext` and the
/// "Run Cleanup Now" button) invoke the statics directly and decide their own
/// threading. Each file is judged by its own creation date, so a sweep only
/// removes artifacts older than the cutoff and never touches newer files.
enum RetentionCleanup {
    /// Audio container extensions treated as recordings (masters + `_partNN` segments).
    /// Mirrors `RecordingDiscovery.supportedExtensions`.
    static let audioExtensions: Set<String> = ["m4a", "wav", "flac", "mp3", "aac"]

    /// Filename suffixes that identify transcript / note artifacts. Matched against
    /// the whole filename (not `pathExtension`) because the JSON sidecars use
    /// compound extensions like `*.richtranscript.json`.
    static let transcriptSuffixes = [
        ".md",
        ".transcript.json",
        ".richtranscript.json",
        ".insights.json",
        ".chat.json",
        ".spokensummary.json",
        // The spoken-summary audio is a derived artifact that travels with its
        // script sidecar — age both under the transcripts policy so they never
        // split (audio gone, script orphaned, or vice versa).
        ".spokensummary.m4a",
    ]

    static func isTranscriptFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return transcriptSuffixes.contains { lower.hasSuffix($0) }
    }

    /// A recording is an audio file, or a non-transcript JSON sidecar (recording
    /// metadata, resume `*.queue.json`) that travels with the audio.
    static func isRecordingFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if isTranscriptFile(name) { return false }
        if audioExtensions.contains(url.pathExtension.lowercased()) { return true }
        return name.hasSuffix(".json")
    }

    static func matches(_ url: URL, category: RetentionCategory) -> Bool {
        switch category {
        case .recordings: isRecordingFile(url)
        case .transcripts: isTranscriptFile(url.lastPathComponent)
        }
    }

    /// Deletes files in `folders` matching `category` whose creation date is more
    /// than `days` days in the past. Folders are de-duplicated by resolved path;
    /// missing folders are skipped. Never throws — individual delete failures are
    /// logged and simply not counted.
    @discardableResult
    static func cleanup(
        category: RetentionCategory,
        olderThanDays days: Int,
        in folders: [URL],
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> RetentionCleanupResult {
        guard days >= 0 else { return RetentionCleanupResult() }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)

        var seen = Set<String>()
        var result = RetentionCleanupResult()

        for folder in folders {
            guard seen.insert(folder.standardizedFileURL.path).inserted else { continue }
            guard fileManager.fileExists(atPath: folder.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard matches(fileURL, category: category) else { continue }
                let values = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .creationDateKey, .fileSizeKey]
                )
                guard values?.isRegularFile ?? false else { continue }
                // Treat a missing creation date as "brand new" so we never delete
                // files we can't reason about.
                let created = values?.creationDate ?? .distantFuture
                guard created < cutoff else { continue }

                let size = Int64(values?.fileSize ?? 0)
                do {
                    try fileManager.removeItem(at: fileURL)
                    result.filesDeleted += 1
                    result.bytesFreed += size
                } catch {
                    log.error("Retention cleanup failed to delete a matching file")
                }
            }
        }

        if result.filesDeleted > 0 {
            log.info("Retention cleanup (\(category.displayName, privacy: .public)) removed \(result.filesDeleted) files, \(result.bytesFreed) bytes")
        }
        return result
    }
}
