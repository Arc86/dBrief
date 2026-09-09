import Foundation
import CryptoKit

/// Disposable per-folder search cache. The actor serializes writers only;
/// searches use independent WAL connections and never read canonical sidecars.
actor LibraryIndex {
    static let shared = LibraryIndex()

    struct RefreshResult: Sendable {
        var indexedRecordings = 0
        var sourceReads = 0
    }

    enum Failure: Error, LocalizedError {
        case unavailableFolder, sourceChanged, invalidWork
        var errorDescription: String? {
            switch self {
            case .unavailableFolder: "The recordings folder could not be fully read. The previous search results have been kept."
            case .sourceChanged: "A recording changed during indexing. Refresh to load the latest version."
            case .invalidWork: "Saved recovery work could not be fully read. The previous search results have been kept."
            }
        }
    }

    private let cacheRoot: URL
    let jobsRoot: URL
    let deliveriesRoot: URL
    let sessionsRoot: URL
    let queueScheduleURL: URL
    let read: @Sendable (URL) throws -> Data
    private let beforeCommit: (@Sendable () throws -> Void)?

    init(cacheRoot: URL = AppSupportPaths.subdirectory("Library Index"),
         jobsRoot: URL = ProcessingJobStore.defaultRootURL,
         deliveriesRoot: URL? = nil, sessionsRoot: URL? = nil, queueScheduleURL: URL? = nil,
         read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
         beforeCommit: (@Sendable () throws -> Void)? = nil) {
        self.cacheRoot = cacheRoot
        self.jobsRoot = jobsRoot
        self.deliveriesRoot = deliveriesRoot ?? jobsRoot.deletingLastPathComponent().appendingPathComponent("Integration Deliveries")
        self.sessionsRoot = sessionsRoot ?? jobsRoot.deletingLastPathComponent().appendingPathComponent("Recording Recovery")
        self.queueScheduleURL = queueScheduleURL ?? jobsRoot.deletingLastPathComponent().appendingPathComponent("Queue/schedule.json")
        self.read = read
        self.beforeCommit = beforeCommit
    }

    nonisolated func databaseURL(for folder: URL) -> URL {
        let hash = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cacheRoot.appendingPathComponent(hash + ".sqlite")
    }

    nonisolated func search(in folder: URL, text: String = "", status: LibraryRecordingStatus? = nil,
                            limit: Int? = nil) async throws -> [RecordingBrowserItem] {
        let url = databaseURL(for: folder)
        return try await Task.detached(priority: .userInitiated) {
            let db = try LibraryDatabase(url: url, readOnly: true)
            var clauses: [String] = []
            var values: [String] = []
            // Treat the field as words, never SQL or FTS syntax. Quote every
            // token and use prefix matches; punctuation and quotes cannot fail
            // the query or introduce operators/column selectors.
            let tokens = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            if !tokens.isEmpty {
                clauses.append("path IN (SELECT path FROM search WHERE search MATCH ?)")
                values.append(tokens.map { "\"\($0)\"*" }.joined(separator: " AND "))
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return []
            }
            if let status {
                clauses.append("status = ?")
                values.append(status.rawValue)
            }
            let condition = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            var sql = "SELECT payload FROM documents" + condition + " ORDER BY created DESC, path ASC"
            if let limit {
                sql += " LIMIT ?"
                values.append(String(max(0, limit)))
            }
            return try db.rows(sql, values).map {
                try JSONDecoder().decode(RecordingBrowserItem.self, from: Data($0[0].utf8))
            }
        }.value
    }

    @discardableResult
    func refresh(in folder: URL, configuredQueueFolders: [URL] = [], rebuild: Bool = false) throws -> RefreshResult {
        // Discover completely before touching the cache. An offline volume or
        // unreadable child must never be interpreted as mass deletion.
        let entries = try discover(in: folder)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = databaseURL(for: folder)
        do {
            return try update(url: url, folder: folder, entries: entries, configuredQueueFolders: configuredQueueFolders, rebuild: rebuild)
        } catch let error as LibraryDatabase.Failure where error.isCorruption {
            // Only our generated cache files; no user-selected file or sidecar.
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: url.path + suffix)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            return try update(url: url, folder: folder, entries: entries, configuredQueueFolders: configuredQueueFolders, rebuild: true)
        }
    }

    private nonisolated func update(url: URL, folder: URL, entries: [RecordingFileEntry], configuredQueueFolders: [URL], rebuild: Bool) throws -> RefreshResult {
        let db = try LibraryDatabase(url: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try db.configureWriter()
        return try db.transaction {
            let newSchema = try db.prepareSchema()
            var result = RefreshResult()
            let workSnapshot = try refreshWorkSources(db: db, folder: folder, entries: entries,
                configuredQueueFolders: configuredQueueFolders, rebuild: rebuild || newSchema, reads: &result.sourceReads)
            let sources = workSnapshot.sources
            let jobs = latestJobs(sources)
            let oldRows = try db.rows("SELECT path, fingerprint FROM documents")
            let old = Dictionary(uniqueKeysWithValues: oldRows.map { ($0[0], $0[1]) })
            var seen: Set<String> = []
            for entry in entries {
                try Task.checkCancellation()
                let path = entry.url.standardizedFileURL.path
                seen.insert(path)
                let job = jobs[path]
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let jobKey = try job.map { String(decoding: try encoder.encode($0), as: UTF8.self) } ?? ""
                let fingerprint = try documentFingerprint(entry.url) + jobKey
                if !rebuild && !newSchema && old[path] == fingerprint { continue }
                let document = try LibraryDocument(entry: entry, job: job, read: read)
                guard try documentFingerprint(entry.url) + jobKey == fingerprint else { throw Failure.sourceChanged }
                let payload = String(decoding: try JSONEncoder().encode(document.item), as: UTF8.self)
                try db.rows("DELETE FROM search WHERE rowid = (SELECT rowid FROM documents WHERE path = ?)", [path])
                try db.rows("INSERT OR REPLACE INTO documents VALUES (?, ?, ?, ?, ?, ?, NULLIF(?, ''))",
                    [path, fingerprint, payload, document.item.libraryStatus!.rawValue, String(document.item.date.timeIntervalSince1970),
                     String(document.unfinishedActions), document.processedAt.map { String($0.timeIntervalSince1970) } ?? ""])
                try db.rows("DELETE FROM people WHERE path = ?", [path])
                for person in document.people {
                    try db.rows("INSERT INTO people VALUES (?, ?, ?)", [path, person.key, person.name])
                }
                try db.rows("INSERT INTO search(rowid, path, body) SELECT rowid, path, ? FROM documents WHERE path = ?", [document.body, path])
                result.indexedRecordings += 1
                result.sourceReads += document.sourceReads
            }
            for path in old.keys where !seen.contains(path) {
                try db.rows("DELETE FROM search WHERE rowid = (SELECT rowid FROM documents WHERE path = ?)", [path])
                try db.rows("DELETE FROM documents WHERE path = ?", [path])
                try db.rows("DELETE FROM people WHERE path = ?", [path])
            }
            try refreshWorkItems(db: db, sources: sources, entries: workSnapshot.audioEntries)
            try beforeCommit?()
            try Task.checkCancellation()
            return result
        }
    }

    private nonisolated func documentFingerprint(_ audio: URL) throws -> String {
        let base = audio.deletingPathExtension()
        return try ([audio] + LibraryDocument.extensions.map { base.appendingPathExtension($0) })
            .map { try fileFingerprint($0) }.joined(separator: "|")
    }

    nonisolated func fileFingerprint(_ url: URL) throws -> String {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return [attrs[.systemFileNumber], attrs[.size], attrs[.modificationDate], attrs[.creationDate]]
                .map { value in
                    if let date = value as? Date { return String(date.timeIntervalSince1970) }
                    return value.map { String(describing: $0) } ?? ""
                }.joined(separator: ":")
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return "missing"
        }
    }

    nonisolated func discover(in folder: URL) throws -> [RecordingFileEntry] {
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw Failure.unavailableFolder }
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles, errorHandler: { _, _ in failed = true; return false }) else { throw Failure.unavailableFolder }
        var result: [RecordingFileEntry] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard RecordingDiscovery.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            guard !stem.hasSuffix(".spokensummary"), stem.range(of: #"_part\d+$"#, options: .regularExpression) == nil else { continue }
            let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey, .fileSizeKey])
            guard attrs.isRegularFile == true else { continue }
            result.append(RecordingFileEntry(url: url.standardizedFileURL, createdAt: attrs.creationDate ?? .distantPast,
                size: Int64(attrs.fileSize ?? 0)))
        }
        if failed { throw Failure.unavailableFolder }
        return result
    }
}

extension Notification.Name {
    static let recordingLibraryChanged = Notification.Name("dBrief.recordingLibraryChanged")
}

enum RecordingLibraryChange {
    static func notify() {
        NotificationCenter.default.post(name: .recordingLibraryChanged, object: nil)
    }
}
