import Foundation

/// One atomic file keeps ordering changes all-or-nothing. Queue sidecars remain
/// the source of processing intent; paths also identify pre-UUID queue files.
struct QueueSchedule: Codable, Equatable, Sendable {
    var version = 1
    var paused = false
    var order: [String] = []
    /// Locations with queued work remain discoverable after a profile switches,
    /// its folder changes, or the profile is deleted. Nil on older schedules.
    var knownFolders: [String]? = nil

    mutating func rememberFolder(_ folder: URL) {
        knownFolders = Array(Set((knownFolders ?? []) + [folder.standardizedFileURL.path])).sorted()
    }

    func discoveryFolders(configured: [URL]) -> [URL] {
        let remembered = (knownFolders ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let orderedFolders = order.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        return Array(Set((configured + remembered + orderedFolders).map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        })).sorted { $0.path < $1.path }
    }

    func ordered<T>(_ items: [T], path: (T) -> String) -> [T] {
        let ranks = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return items.enumerated().sorted {
            let lhs = ranks[path($0.element)] ?? Int.max
            let rhs = ranks[path($1.element)] ?? Int.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }

    mutating func move(path: String, by offset: Int, currentPaths: [String]) {
        var paths = ordered(currentPaths, path: { $0 })
        guard let index = paths.firstIndex(of: path), paths.indices.contains(index + offset) else { return }
        paths.insert(paths.remove(at: index), at: index + offset)
        order = paths
    }
}

/// The manager shares one store for complete schedule/marker transactions. No
/// caller carries a loaded schedule across an await and writes that stale value.
actor QueueScheduleStore {
    struct Files: Sendable {
        var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
        var write: @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    }
    struct Entry: Sendable {
        let audioURL: URL
        let item: QueueItem
        /// Nil means unavailable. Missing masters remain visible and removable.
        let fileSize: Int64?
    }
    struct Snapshot: Sendable {
        let schedule: QueueSchedule
        let items: [Entry]
    }
    nonisolated let url: URL
    private let files: Files
    private var pauseRevision = 0
    init(url: URL = AppSupportPaths.subdirectory("Queue").appendingPathComponent("schedule.json"),
         files: Files = .init()) {
        self.url = url
        self.files = files
    }
    func load() throws -> QueueSchedule {
        guard FileManager.default.fileExists(atPath: url.path) else { return QueueSchedule() }
        let schedule = try JSONDecoder().decode(QueueSchedule.self, from: files.read(url))
        guard schedule.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        return schedule
    }
    func save(_ schedule: QueueSchedule) throws {
        guard schedule.version == 1 else { throw CocoaError(.coderInvalidValue) }
        _ = try load() // Never overwrite an unreadable or future-version schedule.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.write(JSONEncoder().encode(schedule), url)
        guard try load() == schedule else { throw CocoaError(.fileWriteUnknown) }
        RecordingLibraryChange.notify()
    }
    @discardableResult
    func setPaused(_ paused: Bool, revision: Int? = nil) throws -> QueueSchedule {
        if let revision {
            guard revision >= pauseRevision else { return try load() }
            pauseRevision = revision
        }
        var schedule = try load()
        schedule.paused = paused
        try save(schedule)
        return schedule
    }
    func rememberFolder(_ folder: URL) throws {
        var schedule = try load()
        schedule.rememberFolder(folder)
        try save(schedule)
    }
    func snapshot(configuredFolders: [URL], excludingAudioURL: URL? = nil) throws -> Snapshot {
        let schedule = try load()
        let items = Self.discoverQueuedItems(in: schedule.discoveryFolders(configured: configuredFolders))
            .filter { $0.audioURL.standardizedFileURL != excludingAudioURL?.standardizedFileURL }
        let ordered = schedule.ordered(items, path: { $0.audioURL.standardizedFileURL.path })
        return .init(schedule: schedule, items: ordered.map { entry in
            let attributes = try? FileManager.default.attributesOfItem(atPath: entry.audioURL.path)
            return .init(audioURL: entry.audioURL, item: entry.item, fileSize: (attributes?[.size] as? NSNumber)?.int64Value)
        })
    }
    func move(_ audioURL: URL, by offset: Int, configuredFolders: [URL], excludingAudioURL: URL?) throws -> Snapshot {
        let current = try snapshot(configuredFolders: configuredFolders, excludingAudioURL: excludingAudioURL)
        var schedule = current.schedule
        schedule.move(path: audioURL.standardizedFileURL.path, by: offset,
                      currentPaths: current.items.map { $0.audioURL.standardizedFileURL.path })
        try save(schedule)
        return .init(schedule: schedule, items: schedule.ordered(current.items, path: { $0.audioURL.standardizedFileURL.path }))
    }
    func loadItem(for audioURL: URL) throws -> QueueItem? {
        let marker = Self.markerURL(for: audioURL)
        do { return try QueueItem.decode(files.read(marker), from: marker) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    func hasMarker(for audioURL: URL) -> Bool { FileManager.default.fileExists(atPath: Self.markerURL(for: audioURL).path) }

    func saveItem(_ item: QueueItem, for audioURL: URL) throws {
        if let existing = try loadItem(for: audioURL), existing.id != item.id { throw CocoaError(.fileWriteFileExists) }
        // Discovery must be durable before new intent becomes visible.
        try rememberFolder(audioURL.deletingLastPathComponent())
        try writeItem(item, at: Self.markerURL(for: audioURL))
    }
    func retireItem(at audioURL: URL, expectedID: UUID) throws {
        guard let item = try loadItem(for: audioURL) else { return }
        guard item.id == expectedID else { throw CocoaError(.fileWriteFileExists) }
        let marker = Self.markerURL(for: audioURL)
        try FileManager.default.removeItem(at: marker)
        guard !FileManager.default.fileExists(atPath: marker.path) else { throw CocoaError(.fileWriteUnknown) }
        RecordingLibraryChange.notify()
    }
    private func writeItem(_ item: QueueItem, at marker: URL) throws {
        let data = try JSONEncoder().encode(item)
        try files.write(data, marker)
        guard try files.read(marker) == data else { throw CocoaError(.fileWriteUnknown) }
        RecordingLibraryChange.notify()
    }
    private nonisolated static func markerURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("queue.json")
    }

    func removeQueuedItem(at audioURL: URL, lifecycle: RecoveryLifecycle) async throws {
        try await removeQueuedItem(at: audioURL, dismiss: { try await lifecycle.dismiss(id: $0) })
    }

    func removeQueuedItem(at audioURL: URL, dismiss: @Sendable (UUID) async throws -> Void) async throws {
        let marker = Self.markerURL(for: audioURL)
        guard var item = try loadItem(for: audioURL) else { throw CocoaError(.fileReadNoSuchFile) }
        var schedule = try load()
        schedule.order.removeAll { $0 == audioURL.standardizedFileURL.path }
        try save(schedule)
        // A crash during removal must not leave an automatically draining marker.
        item.autoQueued = false
        try writeItem(item, at: marker)
        let deferred = try files.read(marker)
        try await dismiss(item.id)
        // Another actor invocation/external edit may have replaced intent while
        // recovery stores were suspended. Keep that newer marker intact.
        guard try files.read(marker) == deferred else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.removeItem(at: marker)
        RecordingLibraryChange.notify()
    }
}

extension QueueScheduleStore {
    nonisolated static func discoverQueuedItems(in folders: [URL]) -> [(audioURL: URL, item: QueueItem)] {
        var seen = Set<String>()
        let entries = folders.flatMap { queuedEntries(in: $0) }
        let ordered = entries.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.url.path < rhs.url.path : lhs.date < rhs.date
        }
        let unique = ordered.filter { entry in
            seen.insert(entry.url.standardizedFileURL.resolvingSymlinksInPath().path).inserted
        }
        return unique.map { ($0.url, $0.item) }
    }

    /// Stateless scanning for actor snapshots and fixture tests.
    nonisolated static func discoverQueuedItems(in folder: URL) -> [(audioURL: URL, item: QueueItem)] {
        discoverQueuedItems(in: [folder])
    }

    private nonisolated static func queuedEntries(in folder: URL) -> [(url: URL, date: Date, item: QueueItem)] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [(url: URL, date: Date, item: QueueItem)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "json",
                  fileURL.lastPathComponent.hasSuffix(".queue.json") else { continue }
            guard let item = try? QueueItem.load(from: fileURL) else { continue }

            let stem = fileURL.deletingPathExtension().deletingPathExtension()
            let audioURL: URL
            if FileManager.default.fileExists(atPath: stem.appendingPathExtension("m4a").path) {
                audioURL = stem.appendingPathExtension("m4a")
            } else if FileManager.default.fileExists(atPath: stem.appendingPathExtension("flac").path) {
                audioURL = stem.appendingPathExtension("flac")
            } else if let other = RecordingDiscovery.supportedExtensions.sorted().map({ stem.appendingPathExtension($0) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                audioURL = other
            } else { audioURL = stem.appendingPathExtension("m4a") }

            let values = try? fileURL.resourceValues(forKeys: [.creationDateKey])
            let date = values?.creationDate ?? .distantPast
            results.append((url: audioURL, date: date, item: item))
        }

        return results
    }

}
