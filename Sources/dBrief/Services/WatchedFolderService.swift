import Foundation
import UserNotifications

/// Monitors the user's watched folders and feeds newly-dropped audio files into the normal
/// transcription pipeline. A lightweight polling loop is used (rather than FSEvents) for
/// robustness: each cycle re-reads the live settings, so enabling/disabling folders or the
/// master toggle takes effect without restarting the service.
///
/// Behaviour:
/// - A file is only processed once it appears **size-stable across two consecutive scans**,
///   so a file still being copied in isn't grabbed mid-write.
/// - When a folder is first seen, its pre-existing files are recorded as already-processed,
///   so adding a folder transcribes only files dropped in *afterwards* — never an existing
///   library all at once.
/// - Processing is serial and defers to any active recording/processing (one file at a time).
@MainActor
@Observable
final class WatchedFolderService {
    private let appSettings: AppSettings
    private weak var recordingManager: RecordingManager?

    /// Most recent snapshot per folder path, for the two-scan stability check (in-memory).
    private var previousSnapshots: [String: [WatchedFileSnapshot]] = [:]
    /// Absolute paths already handled, persisted so relaunches don't reprocess.
    /// `processedOrder` is the insertion-ordered source of truth (oldest first) so the cap
    /// evicts the genuinely-oldest entries; `processedPaths` is its membership index.
    private var processedOrder: [String]
    private var processedPaths: Set<String>
    /// Folder paths whose existing contents have been seeded as processed.
    private var knownFolders: Set<String>

    private var monitorTask: Task<Void, Never>?

    /// Poll interval. Transcription itself dwarfs this, so a few seconds is plenty.
    private let pollInterval: Duration = .seconds(4)
    /// Cap on the persisted processed-path history to keep UserDefaults bounded.
    private let maxProcessedPaths = 5000

    init(appSettings: AppSettings, recordingManager: RecordingManager) {
        self.appSettings = appSettings
        self.recordingManager = recordingManager
        let stored = UserDefaults.standard.stringArray(forKey: Keys.processedPaths) ?? []
        self.processedOrder = stored
        self.processedPaths = Set(stored)
        self.knownFolders = Set(UserDefaults.standard.stringArray(forKey: Keys.knownFolders) ?? [])
    }

    private enum Keys {
        static let processedPaths = "watchedFolderProcessedPaths"
        static let knownFolders = "watchedFolderKnownFolders"
    }

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runScanCycle()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(4))
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: - Scan cycle

    private func runScanCycle() async {
        guard appSettings.watchedFoldersEnabled else { return }
        let folders = appSettings.watchedFolders.filter(\.isEnabled)
        guard !folders.isEmpty else { return }
        // Don't contend with an active recording or in-flight processing.
        guard recordingManager?.isIdle == true else { return }

        // Resolve bookmarks + enumerate off the main thread.
        let snapshotsByFolder: [String: [WatchedFileSnapshot]] = await Task.detached {
            var result: [String: [WatchedFileSnapshot]] = [:]
            for folder in folders {
                guard let url = folder.resolveURL() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                result[folder.displayPath] = WatchedFolderScanner.audioFiles(in: url)
            }
            return result
        }.value

        for (folderPath, current) in snapshotsByFolder {
            // First time we ever see this folder: treat its current contents as already
            // handled so only newly-dropped files get processed.
            if !knownFolders.contains(folderPath) {
                knownFolders.insert(folderPath)
                for snap in current { insertProcessed(snap.path) }
                previousSnapshots[folderPath] = current
                persistState()
                continue
            }

            let previous = previousSnapshots[folderPath] ?? []
            previousSnapshots[folderPath] = current

            let ready = WatchedFolderScanner.newlyStableFiles(
                current: current, previous: previous, processed: processedPaths
            )
            for snap in ready {
                // Re-check idleness before each file — a recording may have started.
                guard recordingManager?.isIdle == true else { return }
                let url = URL(fileURLWithPath: snap.path)
                markProcessed(snap.path)
                if appSettings.watchedFolderNotifyOnDetect {
                    notifyDetected(url.lastPathComponent)
                }
                await recordingManager?.processWatchedFile(url)
            }
        }
    }

    // MARK: - Processed-path bookkeeping

    private func markProcessed(_ path: String) {
        insertProcessed(path)
        persistState()
    }

    /// Record a path as processed, preserving insertion order and evicting the genuinely
    /// oldest entries when the cap is exceeded. No-op for an already-known path.
    private func insertProcessed(_ path: String) {
        guard processedPaths.insert(path).inserted else { return }
        processedOrder.append(path)
        if processedOrder.count > maxProcessedPaths {
            let overflow = processedOrder.count - maxProcessedPaths
            for old in processedOrder.prefix(overflow) { processedPaths.remove(old) }
            processedOrder.removeFirst(overflow)
        }
    }

    private func persistState() {
        UserDefaults.standard.set(processedOrder, forKey: Keys.processedPaths)
        UserDefaults.standard.set(Array(knownFolders), forKey: Keys.knownFolders)
    }

    /// Forget a folder's seed/known state so re-adding it re-seeds cleanly. Called when a
    /// folder is removed in Settings.
    func forget(folderPath: String) {
        knownFolders.remove(folderPath)
        previousSnapshots[folderPath] = nil
        persistState()
    }

    // MARK: - Notifications

    private func notifyDetected(_ fileName: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "New audio detected"
        content.body = "Transcribing \(fileName) from a watched folder…"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "watched-folder-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
