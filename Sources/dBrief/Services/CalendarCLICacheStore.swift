import Foundation
import CryptoKit
import Darwin
import os

struct CalendarCLIStoredListSnapshot: Codable, Sendable {
    static let currentVersion = 1
    var version: Int = currentVersion
    var scope: CalendarCLIScope
    var window: CalendarCLIWindow
    var entries: [CalendarCLIEntry]
    var lastSuccessfulRefresh: Date?
    var lastAttempt: Date?
}

enum CalendarCLIPersistenceOutcome: Sendable, Equatable {
    case saved, failed
}

/// Calendar cache storage. All paths below the root are opened relative to a
/// directory descriptor with O_NOFOLLOW, including reads and atomic writes.
final class CalendarCLICacheStore: @unchecked Sendable {
    let directory: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    static let listRetentionInterval: TimeInterval = 90 * 86_400
    static let detailRetentionInterval: TimeInterval = 7 * 86_400
    static let maxListSnapshots = 128
    static let maxDetailEntries = 500

    init(directory: URL = AppSupportPaths.subdirectory("CalendarCLI"),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
        lock.withLock {
            guard let root = rootFD(create: true) else { return }
            defer { close(root) }
            for kind in ["lists", "details"] {
                if let fd = childDirectoryFD(parent: root, name: kind, create: true) { close(fd) }
            }
            sweep(root: root)
        }
    }

    func loadList(scope: CalendarCLIScope, window: CalendarCLIWindow) -> CalendarCLIStoredListSnapshot? {
        lock.withLock {
            guard let fd = scopeFD(kind: "lists", scope: scope, create: false) else { return nil }
            defer { close(fd) }
            let name = listName(window)
            guard let snapshot: CalendarCLIStoredListSnapshot = read(name, from: fd),
                  valid(snapshot, scope: scope, window: window) else { return nil }
            return snapshot
        }
    }

    @discardableResult
    func storeList(_ snapshot: CalendarCLIStoredListSnapshot) -> CalendarCLIPersistenceOutcome {
        lock.withLock {
            guard valid(snapshot, scope: snapshot.scope, window: snapshot.window),
                  let fd = scopeFD(kind: "lists", scope: snapshot.scope, create: true) else { return .failed }
            defer { close(fd) }
            guard write(snapshot, name: listName(snapshot.window), to: fd) else {
                Logger.calendar.warning("Calendar CLI cache: could not persist list snapshot")
                return .failed
            }
            sweepAll()
            return .saved
        }
    }

    func updateListAttempt(scope: CalendarCLIScope, window: CalendarCLIWindow, date: Date) {
        lock.withLock {
            guard let fd = scopeFD(kind: "lists", scope: scope, create: false) else { return }
            defer { close(fd) }
            let name = listName(window)
            guard var snapshot: CalendarCLIStoredListSnapshot = read(name, from: fd),
                  valid(snapshot, scope: scope, window: window) else { return }
            snapshot.lastAttempt = date
            _ = write(snapshot, name: name, to: fd)
        }
    }

    func loadDetail(scope: CalendarCLIScope, key: CalendarCLIOccurrenceKey) -> CalendarCLIEntry? {
        lock.withLock {
            guard let fd = scopeFD(kind: "details", scope: scope, create: false) else { return nil }
            defer { close(fd) }
            guard let entry: CalendarCLIEntry = read(detailName(scope: scope, key: key), from: fd),
                  entry.key == key, validDetail(entry) else { return nil }
            return entry
        }
    }

    @discardableResult
    func storeDetail(scope: CalendarCLIScope, entry: CalendarCLIEntry) -> CalendarCLIPersistenceOutcome {
        lock.withLock {
            guard validDetail(entry),
                  let fd = scopeFD(kind: "details", scope: scope, create: true) else { return .failed }
            defer { close(fd) }
            guard write(entry, name: detailName(scope: scope, key: entry.key), to: fd) else {
                Logger.calendar.warning("Calendar CLI cache: could not persist roster")
                return .failed
            }
            sweepAll()
            return .saved
        }
    }

    func purgeRosters(scope: CalendarCLIScope, policy: CalendarCLIConfig.AttendeePolicy, cap: Int) {
        lock.withLock {
            guard let fd = scopeFD(kind: "details", scope: scope, create: false) else { return }
            defer { close(fd) }
            for name in names(in: fd) {
                guard let entry: CalendarCLIEntry = read(name, from: fd), validDetail(entry) else {
                    _ = unlinkat(fd, name, 0)
                    continue
                }
                if policy == .never || (entry.attendeeState == .loaded && entry.event.attendees.count > cap) {
                    _ = unlinkat(fd, name, 0)
                }
            }
        }
    }

    func purgeAll() {
        lock.withLock {
            guard let root = rootFD(create: false) else { return }
            defer { close(root) }
            for kind in ["lists", "details"] {
                guard let type = childDirectoryFD(parent: root, name: kind, create: false) else { continue }
                for scope in names(in: type) {
                    guard let fd = childDirectoryFD(parent: type, name: scope, create: false) else { continue }
                    for name in names(in: fd) { _ = unlinkat(fd, name, 0) }
                    close(fd)
                    _ = unlinkat(type, scope, AT_REMOVEDIR)
                }
                close(type)
            }
        }
    }

    internal func listFileURL(scope: CalendarCLIScope, window: CalendarCLIWindow) -> URL {
        directory.appendingPathComponent("lists").appendingPathComponent(scope.digest).appendingPathComponent(listName(window))
    }

    internal func detailFileURL(scope: CalendarCLIScope, key: CalendarCLIOccurrenceKey) -> URL {
        directory.appendingPathComponent("details").appendingPathComponent(scope.digest)
            .appendingPathComponent(detailName(scope: scope, key: key))
    }

    private func listName(_ window: CalendarCLIWindow) -> String {
        "\(Int(window.start.timeIntervalSince1970))-\(Int(window.end.timeIntervalSince1970)).json"
    }

    private func detailName(scope: CalendarCLIScope, key: CalendarCLIOccurrenceKey) -> String {
        let identity = [scope.digest, key.mailbox, key.calendar, key.resourceURI,
                        String(key.occurrenceStart.timeIntervalSince1970)].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return "\(digest).json"
    }

    private func valid(_ snapshot: CalendarCLIStoredListSnapshot, scope: CalendarCLIScope, window: CalendarCLIWindow) -> Bool {
        guard snapshot.version == CalendarCLIStoredListSnapshot.currentVersion,
              snapshot.scope == scope, snapshot.window == window,
              let success = snapshot.lastSuccessfulRefresh, success.isFinite else { return false }
        let age = now().timeIntervalSince(success)
        return age >= -300 && age < Self.listRetentionInterval
    }

    private func validDetail(_ entry: CalendarCLIEntry) -> Bool {
        guard let fetched = entry.detailsFetchedAt, fetched.isFinite else { return false }
        let age = now().timeIntervalSince(fetched)
        return age >= -300 && age < Self.detailRetentionInterval
    }

    private func rootFD(create: Bool) -> Int32? {
        if create {
            // Only the cache root itself is created by path; a symlink at that
            // path is rejected by lstat before the directory is opened.
            var info = stat()
            if lstat(directory.path, &info) != 0 {
                do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]) } catch { return nil }
            }
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        guard fchmod(fd, 0o700) == 0 else { close(fd); return nil }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = directory
        try? target.setResourceValues(values)
        return fd
    }

    private func childDirectoryFD(parent: Int32, name: String, create: Bool) -> Int32? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        if create { _ = mkdirat(parent, name, 0o700) }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        guard fchmod(fd, 0o700) == 0 else { close(fd); return nil }
        return fd
    }

    private func scopeFD(kind: String, scope: CalendarCLIScope, create: Bool) -> Int32? {
        guard let root = rootFD(create: create) else { return nil }
        defer { close(root) }
        guard let type = childDirectoryFD(parent: root, name: kind, create: create) else { return nil }
        defer { close(type) }
        return childDirectoryFD(parent: type, name: scope.digest, create: create)
    }

    private func read<T: Decodable>(_ name: String, from directoryFD: Int32, touchAccess: Bool = true) -> T? {
        guard name.hasSuffix(".json") else { return nil }
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= 8 * 1024 * 1024 else { return nil }
        guard fchmod(fd, 0o600) == 0 else { return nil }
        guard let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd(),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        if touchAccess { _ = futimes(fd, nil) } // count eviction recency; expiry uses JSON timestamps
        return value
    }

    private func write(_ value: some Encodable, name: String, to directoryFD: Int32) -> Bool {
        guard name.hasSuffix(".json"),
              let data = try? JSONEncoder().encode(value) else { return false }
        let temp = ".\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { return false }
        var success = fchmod(fd, 0o600) == 0
        if success {
            success = data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return true }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                    if count <= 0 { return false }
                    offset += count
                }
                return true
            }
        }
        if success { success = fsync(fd) == 0 }
        if close(fd) != 0 { success = false }
        if success { success = renameat(directoryFD, temp, directoryFD, name) == 0 }
        if !success { _ = unlinkat(directoryFD, temp, 0) }
        return success
    }

    private func names(in fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { return [] }
        guard let stream = fdopendir(copy) else { close(copy); return [] }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { result.append(name) }
        }
        return result
    }

    private func sweepAll() {
        guard let root = rootFD(create: false) else { return }
        defer { close(root) }
        sweep(root: root)
    }

    private func sweep(root: Int32) {
        for (kind, limit) in [("lists", Self.maxListSnapshots), ("details", Self.maxDetailEntries)] {
            guard let type = childDirectoryFD(parent: root, name: kind, create: false) else { continue }
            defer { close(type) }
            for scope in names(in: type) {
                guard let fd = childDirectoryFD(parent: type, name: scope, create: false) else { continue }
                sweepScope(fd: fd, kind: kind, limit: limit)
                close(fd)
            }
        }
    }

    private func sweepScope(fd: Int32, kind: String, limit: Int) {
        var survivors: [(String, Date)] = []
        for name in names(in: fd) where name.hasSuffix(".json") {
            let validFile: Bool
            if kind == "lists" {
                if let snapshot: CalendarCLIStoredListSnapshot = read(name, from: fd, touchAccess: false),
                   snapshot.version == CalendarCLIStoredListSnapshot.currentVersion,
                   let stamp = snapshot.lastSuccessfulRefresh, stamp.isFinite {
                    let age = now().timeIntervalSince(stamp)
                    validFile = age >= -300 && age < Self.listRetentionInterval
                } else { validFile = false }
            } else {
                if let entry: CalendarCLIEntry = read(name, from: fd, touchAccess: false) { validFile = validDetail(entry) }
                else { validFile = false }
            }
            guard validFile else { _ = unlinkat(fd, name, 0); continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            survivors.append((name, Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))))
        }
        if survivors.count > limit {
            for (name, _) in survivors.sorted(by: { $0.1 < $1.1 }).prefix(survivors.count - limit) {
                _ = unlinkat(fd, name, 0)
            }
        }
    }
}

private extension Date {
    var isFinite: Bool { timeIntervalSince1970.isFinite }
}
