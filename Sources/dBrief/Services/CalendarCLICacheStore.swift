import Foundation
import CryptoKit
import os

/// Persisted day-list snapshot. `lastSuccessfulRefresh` and `lastAttempt` are
/// explicit: a failed or partial refresh updates the attempt stamp only and
/// never advances success or touches entries.
struct CalendarCLIStoredListSnapshot: Codable, Sendable {
    static let currentVersion = 1

    var version: Int = CalendarCLIStoredListSnapshot.currentVersion
    var scope: CalendarCLIScope
    var window: CalendarCLIWindow
    var entries: [CalendarCLIEntry]
    var lastSuccessfulRefresh: Date?
    var lastAttempt: Date?
}

/// Atomic, versioned cache storage for the Claude CLI calendar source.
/// Filenames are digests of scope/occurrence identity — the CLI command is
/// never part of a path. Corrupt or unsupported files surface as a cache miss,
/// never as a successful empty result.
final class CalendarCLICacheStore: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()

    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    static let maxListSnapshots = 32
    static let maxDetailEntries = 500

    init(directory: URL = AppSupportPaths.subdirectory("CalendarCLI")) {
        self.directory = directory
        try? Self.prepareDirectory(directory)
    }

    // MARK: - List snapshots

    func loadList(scope: CalendarCLIScope, window: CalendarCLIWindow) -> CalendarCLIStoredListSnapshot? {
        lock.withLock {
            guard let data = try? Data(contentsOf: listFileURL(scope: scope, window: window)) else { return nil }
            do {
                let snapshot = try JSONDecoder().decode(CalendarCLIStoredListSnapshot.self, from: data)
                guard snapshot.version == CalendarCLIStoredListSnapshot.currentVersion else { return nil }
                Self.touch(listFileURL(scope: scope, window: window))
                return snapshot
            } catch {
                Logger.calendar.warning("Calendar CLI cache: unreadable list snapshot treated as a miss")
                return nil
            }
        }
    }

    func storeList(_ snapshot: CalendarCLIStoredListSnapshot) {
        lock.withLock {
            let url = listFileURL(scope: snapshot.scope, window: snapshot.window)
            do {
                try Self.writeAtomically(snapshot, to: url)
            } catch {
                Logger.calendar.warning("Calendar CLI cache: could not persist list snapshot")
                return
            }
            Self.applyRetention(directory: listsDirectory(for: snapshot.scope),
                                limit: Self.maxListSnapshots)
        }
    }

    /// Records a failed/partial attempt without touching entries or success.
    func updateListAttempt(scope: CalendarCLIScope, window: CalendarCLIWindow, date: Date) {
        lock.withLock {
            let url = listFileURL(scope: scope, window: window)
            guard var snapshot = Self.readListSnapshot(at: url) else { return }
            snapshot.lastAttempt = date
            try? Self.writeAtomically(snapshot, to: url)
        }
    }

    // MARK: - Details (rosters)

    func loadDetail(scope: CalendarCLIScope, key: CalendarCLIOccurrenceKey) -> CalendarCLIEntry? {
        lock.withLock {
            let url = detailFileURL(scope: scope, key: key)
            guard let data = try? Data(contentsOf: url) else { return nil }
            do {
                let entry = try JSONDecoder().decode(CalendarCLIEntry.self, from: data)
                Self.touch(url)
                return entry
            } catch {
                Logger.calendar.warning("Calendar CLI cache: unreadable roster treated as a miss")
                return nil
            }
        }
    }

    func storeDetail(scope: CalendarCLIScope, entry: CalendarCLIEntry) {
        lock.withLock {
            do {
                try Self.writeAtomically(entry, to: detailFileURL(scope: scope, key: entry.key))
            } catch {
                Logger.calendar.warning("Calendar CLI cache: could not persist roster")
                return
            }
            Self.applyRetention(directory: detailsDirectory(for: scope),
                                limit: Self.maxDetailEntries)
        }
    }

    /// Purges rosters incompatible with the new policy or cap. Lowering the
    /// cap or selecting Never drops stored people entirely; metadata already
    /// attached to recordings is untouched (that lives in recording sidecars).
    func purgeRosters(scope: CalendarCLIScope, policy: CalendarCLIConfig.AttendeePolicy, cap: Int) {
        lock.withLock {
            let details = directory.appendingPathComponent("details", isDirectory: true)
                .appendingPathComponent(scope.digest, isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: details, includingPropertiesForKeys: nil) else { return }
            for file in files {
                guard let entry = try? JSONDecoder().decode(CalendarCLIEntry.self, from: Data(contentsOf: file)) else {
                    try? FileManager.default.removeItem(at: file) // unreadable: drop
                    continue
                }
                let incompatible = policy == .never
                    || (entry.attendeeState == .loaded && entry.event.attendees.count > cap)
                if incompatible { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    func purgeAll() {
        lock.withLock {
            for component in ["lists", "details"] {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(component, isDirectory: true))
            }
        }
    }

    // MARK: - Paths

    private func listsDirectory(for scope: CalendarCLIScope) -> URL {
        directory.appendingPathComponent("lists", isDirectory: true)
            .appendingPathComponent(scope.digest, isDirectory: true)
    }

    private func detailsDirectory(for scope: CalendarCLIScope) -> URL {
        directory.appendingPathComponent("details", isDirectory: true)
            .appendingPathComponent(scope.digest, isDirectory: true)
    }

    internal func listFileURL(scope: CalendarCLIScope, window: CalendarCLIWindow) -> URL {
        listsDirectory(for: scope)
            .appendingPathComponent("\(Int(window.start.timeIntervalSince1970))-\(Int(window.end.timeIntervalSince1970)).json")
    }

    internal func detailFileURL(scope: CalendarCLIScope, key: CalendarCLIOccurrenceKey) -> URL {
        let identity = [scope.digest, key.mailbox, key.calendar, key.resourceURI,
                        String(key.occurrenceStart.timeIntervalSince1970)].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return detailsDirectory(for: scope).appendingPathComponent("\(digest).json")
    }

    // MARK: - Helpers

    private static func prepareDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for component in ["lists", "details"] {
            try fileManager.createDirectory(
                at: directory.appendingPathComponent(component, isDirectory: true),
                withIntermediateDirectories: true)
        }
        // Exclude the cache from device backups where the volume supports it.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = directory
        try? target.setResourceValues(values)
    }

    private static func readListSnapshot(at url: URL) -> CalendarCLIStoredListSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CalendarCLIStoredListSnapshot.self, from: data)
    }

    private static func writeAtomically(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    /// Read access refreshes the modification date so LRU retention reflects
    /// actual use rather than write order.
    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Evicts entries older than the retention interval, then the least
    /// recently used beyond the count limit. Bounded sweeps; failures ignored.
    private static func applyRetention(directory: URL, limit: Int) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dated: [(url: URL, modified: Date)] = files.compactMap { url in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, modified)
        }
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        for entry in dated where entry.modified < cutoff {
            try? fileManager.removeItem(at: entry.url)
        }
        let survivors = dated.filter { $0.modified >= cutoff }
        guard survivors.count > limit else { return }
        for entry in survivors.sorted(by: { $0.modified < $1.modified }).prefix(survivors.count - limit) {
            try? fileManager.removeItem(at: entry.url)
        }
    }
}
