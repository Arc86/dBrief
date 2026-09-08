import Foundation

/// One atomic file keeps ordering changes all-or-nothing. Queue sidecars remain
/// the source of processing intent; paths also identify pre-UUID queue files.
struct QueueSchedule: Codable, Equatable, Sendable {
    var version = 1
    var paused = false
    var order: [String] = []

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

struct QueueScheduleStore: Sendable {
    let url: URL
    init(url: URL = AppSupportPaths.subdirectory("Queue").appendingPathComponent("schedule.json")) {
        self.url = url
    }
    func load() throws -> QueueSchedule {
        guard FileManager.default.fileExists(atPath: url.path) else { return QueueSchedule() }
        let schedule = try JSONDecoder().decode(QueueSchedule.self, from: Data(contentsOf: url))
        guard schedule.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        return schedule
    }
    func save(_ schedule: QueueSchedule) throws {
        guard schedule.version == 1 else { throw CocoaError(.coderInvalidValue) }
        // Do not overwrite an unreadable or future-version schedule.
        _ = try load()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(schedule).write(to: url, options: .atomic)
        guard try load() == schedule else { throw CocoaError(.fileWriteUnknown) }
    }

    func removeQueuedItem(at audioURL: URL, lifecycle: RecoveryLifecycle) async throws {
        let marker = audioURL.deletingPathExtension().appendingPathExtension("queue.json")
        var item = try QueueItem.load(from: marker)
        var schedule = try load()
        schedule.order.removeAll { $0 == audioURL.standardizedFileURL.path }
        try save(schedule)
        // A crash during removal must not leave an automatically draining marker.
        item.autoQueued = false
        try JSONEncoder().encode(item).write(to: marker, options: .atomic)
        try await lifecycle.dismiss(id: item.id)
        try FileManager.default.removeItem(at: marker)
    }
}
