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
    var privacyCleanupFailures: Int = 0

    /// One-line, user-facing summary for the Settings UI.
    var summary: String {
        if privacyCleanupFailures > 0 {
            return "Deleted \(filesDeleted) files. Some privacy evidence could not be removed; retry cleanup when storage is available."
        }
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
        if isTranscriptFile(name) || name.hasSuffix(".privacy.json") { return false }
        if audioExtensions.contains(url.pathExtension.lowercased()) { return true }
        return name.hasSuffix(".json")
    }

    static func matches(_ url: URL, category: RetentionCategory) -> Bool {
        switch category {
        case .recordings: isRecordingFile(url)
        case .transcripts: isTranscriptFile(url.lastPathComponent)
        }
    }

    /// Capture pending ownership before generic retention removes metadata.
    /// Reconcile evidence afterward, only if no master or segment survives.
    static func cleanupWithPrivacy(
        category: RetentionCategory, olderThanDays days: Int, in folders: [URL],
        store: PrivacyReceiptStore = .shared, now: Date = Date(), protectedBases: Set<String> = [],
        extraRecordingIDs: [URL: Set<UUID>] = [:]
    ) async -> RetentionCleanupResult {
        guard category == .recordings, days >= 0 else {
            return cleanup(category: category, olderThanDays: days, in: folders, now: now, protectedBases: protectedBases)
        }
        let fm = FileManager.default
        var candidates: [URL: [URL]] = [:]
        for folder in Set(folders) {
            let protected = queuedRecordingBases(in: folder, fileManager: fm).union(protectedBases)
            let files: [URL] = {
                guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
                return enumerator.compactMap { $0 as? URL }
            }()
            for url in files {
                var receipts: [URL]
                if url.lastPathComponent.hasSuffix(".privacy.json") {
                    if await store.isPendingReceipt(url) { continue }
                    receipts = [url]
                }
                else if audioExtensions.contains(url.pathExtension.lowercased()), !isTranscriptFile(url.lastPathComponent) {
                    receipts = [PrivacyReceiptLifecycle.receiptURL(for: url)]
                    let stem = url.deletingPathExtension().lastPathComponent
                    if let range = stem.range(of: #"_part[0-9]+$"#, options: .regularExpression) {
                        // A parent may have only pending evidence after a failed
                        // bind, and its master may have aged out in an earlier
                        // sweep. Keep the segment's own receipt separate.
                        receipts.append(url.deletingLastPathComponent()
                            .appendingPathComponent(String(stem[..<range.lowerBound]) + ".privacy.json"))
                    }
                } else { continue }
                for receipt in receipts {
                    guard candidates[receipt] == nil, !isProtectedByQueue(receipt, queuedBases: protected) else { continue }
                    let audio = receipt.deletingPathExtension().deletingPathExtension().appendingPathExtension("m4a")
                    let ids = extraRecordingIDs.reduce(into: Set<UUID>()) { ids, entry in
                        let ownerReceipt = PrivacyReceiptLifecycle.receiptURL(for: entry.key)
                        if ownerReceipt.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(ownerReceipt.lastPathComponent)
                            == receipt.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(receipt.lastPathComponent) {
                            ids.formUnion(entry.value)
                        }
                    }
                    candidates[receipt] = await store.deletionTargets(for: audio, recordingIDs: ids)
                }
            }
        }
        var result = cleanup(category: category, olderThanDays: days, in: folders, now: now, protectedBases: protectedBases)
        for (receipt, targets) in candidates {
            do {
                guard try !PrivacyReceiptLifecycle.hasSurvivingAudio(for: receipt) else { continue }
                let values = try? receipt.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                try await store.removeEvidence(at: targets)
                if values?.isRegularFile == true {
                    result.filesDeleted += 1
                    result.bytesFreed += Int64(values?.fileSize ?? 0)
                }
            } catch {
                result.privacyCleanupFailures += 1
                log.error("Retention could not reconcile privacy evidence")
            }
        }
        result.privacyCleanupFailures += await store.retryDeletedEvidenceCleanup()
        return result
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
        now: Date = Date(),
        protectedBases: Set<String> = []
    ) -> RetentionCleanupResult {
        guard days >= 0 else { return RetentionCleanupResult() }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)

        var seen = Set<String>()
        var result = RetentionCleanupResult()

        for folder in folders {
            guard seen.insert(folder.standardizedFileURL.path).inserted else { continue }
            guard fileManager.fileExists(atPath: folder.path) else { continue }
            // A queue sidecar represents unfinished processing. Protect its master,
            // metadata, segments, derived transcript outputs, and the queue marker
            // itself until the durable transcription checkpoint retires that marker.
            let queuedBases = queuedRecordingBases(in: folder, fileManager: fileManager).union(protectedBases)
            guard let enumerator = fileManager.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard matches(fileURL, category: category) else { continue }
                if isProtectedByQueue(fileURL, queuedBases: queuedBases) {
                    continue
                }
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

    private static func queuedRecordingBases(
        in folder: URL,
        fileManager: FileManager
    ) -> Set<String> {
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var bases = Set<String>()
        for case let url as URL in enumerator
        where url.lastPathComponent.lowercased().hasSuffix(".queue.json") {
            bases.insert(
                url.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appendingPathComponent(url.deletingPathExtension().deletingPathExtension().lastPathComponent).standardizedFileURL.path
            )
        }
        return bases
    }

    private static func isProtectedByQueue(
        _ url: URL,
        queuedBases: Set<String>
    ) -> Bool {
        let lowerName = url.lastPathComponent.lowercased()
        let knownSuffixes = [".queue.json", ".privacy.json"] + transcriptSuffixes
        let base = knownSuffixes.first(where: { lowerName.hasSuffix($0) }).map { suffix in
            let stem = String(url.lastPathComponent.dropLast(suffix.count))
            return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(stem)
                .standardizedFileURL.path
        } ?? url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent).standardizedFileURL.path
        if queuedBases.contains(base) { return true }

        // Segments are named `<master>_partNN.<ext>`.
        guard let range = base.range(of: #"_part[0-9]+$"#, options: .regularExpression)
        else { return false }
        return queuedBases.contains(String(base[..<range.lowerBound]))
    }
}
