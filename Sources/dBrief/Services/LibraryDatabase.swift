import Foundation
import SQLite3

/// One connection, owned by one synchronous operation. Readers open separate
/// connections so WAL keeps the committed snapshot searchable during a rebuild.
final class LibraryDatabase {
    struct Failure: Error, LocalizedError {
        let code: Int32
        var isCorruption: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
        var errorDescription: String? { "The search index could not be read or updated. Try rebuilding it. Your recordings are unchanged." }
    }

    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let code = sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else {
            sqlite3_close(handle)
            handle = nil
            throw Failure(code: code)
        }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close(handle) }

    @discardableResult
    func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let code = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
            try check(code)
        }
        var result: [[String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw Failure(code: code) }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
    }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try rows("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try rows("COMMIT")
            return result
        } catch {
            _ = try? rows("ROLLBACK")
            throw error
        }
    }

    func configureWriter() throws {
        try rows("PRAGMA journal_mode=WAL")
        try rows("PRAGMA secure_delete=ON")
    }

    /// Called inside the same transaction that populates the cache. A schema
    /// upgrade must not publish an empty library before rebuilding its rows.
    func prepareSchema() throws -> Bool {
        let version = try rows("PRAGMA user_version").first?.first
        // Version 3 revalidates queue/schedule sources that older caches could
        // have accepted before strict schema checks and cross-folder discovery.
        guard version != "3" else { return false }
        try rows("DROP TABLE IF EXISTS documents")
        try rows("DROP TABLE IF EXISTS search")
        try rows("DROP TABLE IF EXISTS jobs")
        try rows("DROP TABLE IF EXISTS work_sources")
        try rows("DROP TABLE IF EXISTS work")
        try rows("DROP TABLE IF EXISTS work_search")
        try rows("DROP TABLE IF EXISTS people")
        try rows("CREATE TABLE documents(path TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL, created REAL NOT NULL, unfinishedActions INTEGER NOT NULL, processedAt REAL)")
        try rows("CREATE INDEX documents_status_date ON documents(status, created DESC)")
        try rows("CREATE INDEX documents_processing_date ON documents(processedAt DESC)")
        try rows("CREATE TABLE people(path TEXT NOT NULL, key TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(path, key))")
        try rows("CREATE INDEX people_key ON people(key, path)")
        try rows("CREATE VIRTUAL TABLE search USING fts5(path UNINDEXED, body, tokenize='unicode61 remove_diacritics 2', prefix='2 3 4')")
        try rows("CREATE TABLE work_sources(path TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, payload TEXT NOT NULL)")
        try rows("CREATE TABLE work(id TEXT PRIMARY KEY, payload TEXT NOT NULL, title TEXT NOT NULL, audioPath TEXT, failed INTEGER NOT NULL, created REAL NOT NULL)")
        try rows("CREATE INDEX work_failure_date ON work(failed, created)")
        try rows("CREATE VIRTUAL TABLE work_search USING fts5(id UNINDEXED, body, tokenize='unicode61 remove_diacritics 2', prefix='2 3 4')")
        try rows("PRAGMA user_version=3")
        return true
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw Failure(code: code) }
    }
}
