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
        ".reprocessing.json",
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
        let ownership = RetentionOwnership(folders: folders, trustedAudio: Set(extraRecordingIDs.keys))
        var candidates: [URL: [URL]] = [:]
        for folder in Set(folders) {
            let protected = queuedRecordingBases(in: folder, fileManager: fm).union(protectedBases)
            let files = RetentionOwnership.regularFiles(in: [folder], fileManager: fm)
            for url in files {
                var receipts: [URL]
                if url.lastPathComponent.hasSuffix(".privacy.json") {
                    if await store.isPendingReceipt(url) { continue }
                    guard (try? await store.load(from: url)) != nil else { continue }
                    receipts = [url]
                }
                else if ownership.audio.contains(url) {
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
        var result = cleanup(category: category, olderThanDays: days, in: folders, now: now,
                             protectedBases: protectedBases, trustedAudio: Set(extraRecordingIDs.keys))
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
        protectedBases: Set<String> = [],
        trustedAudio: Set<URL> = []
    ) -> RetentionCleanupResult {
        guard days >= 0 else { return RetentionCleanupResult() }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)

        let ownership = RetentionOwnership(folders: folders, trustedAudio: trustedAudio, fileManager: fileManager)
        let queuedBases = folders.reduce(into: protectedBases) {
            $0.formUnion(queuedRecordingBases(in: $1, fileManager: fileManager))
        }
        var result = RetentionCleanupResult()
        // Linked notes precede insights, and ownership metadata comes last.
        // Check dependencies again after earlier candidates have been removed.
        func rank(_ url: URL) -> Int {
            if url.pathExtension == "md" { return 0 }
            if url.lastPathComponent.hasSuffix(".insights.json") { return 2 }
            return ownership.dependencies[url] == nil ? 1 : 3
        }
        let candidates = ownership.artifacts.sorted {
            rank($0) == rank($1) ? $0.path < $1.path : rank($0) < rank($1)
        }
        for fileURL in candidates {
            guard matches(fileURL, category: category),
                  !isProtectedByQueue(fileURL, queuedBases: queuedBases),
                  ownership.owners[fileURL]?.contains(where: { isProtectedByQueue($0, queuedBases: queuedBases) }) != true,
                  RetentionOwnership.isRegularUnlinked(fileURL, fileManager: fileManager) else { continue }
            if ownership.dependencies[fileURL]?.contains(where: { fileManager.fileExists(atPath: $0.path) }) == true {
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            guard let created = values?.creationDate, created < cutoff else { continue }
            do {
                try fileManager.removeItem(at: fileURL)
                result.filesDeleted += 1
                result.bytesFreed += Int64(values?.fileSize ?? 0)
            } catch {
                log.error("Retention cleanup failed to delete an owned file")
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
