import Foundation
import Testing
@testable import dBrief

@Suite("Serialized queue persistence")
struct QueuePersistenceTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func item(auto: Bool = false) -> QueueItem {
        .init(transcribe: true, summary: true, actionItems: false, tags: false, autoQueued: auto, profileID: UUID())
    }
    @Test @MainActor func simultaneousScheduleUpdatesPreservePauseOrderAndEveryFolder() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"), files: .init(
            read: { url in #expect(!Thread.isMainThread); return try Data(contentsOf: url) },
            write: { data, url in #expect(!Thread.isMainThread); try data.write(to: url, options: .atomic) }))
        let first = root.appendingPathComponent("a.m4a")
        let second = root.appendingPathComponent("b.m4a")
        for audio in [first, second] {
            try Data("audio".utf8).write(to: audio)
            try await store.saveItem(item(), for: audio)
        }
        try await store.save(QueueSchedule(order: [first.path, second.path], knownFolders: [root.path]))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 { group.addTask { try await store.rememberFolder(root.appendingPathComponent("folder-\(i)")) } }
            group.addTask { _ = try await store.setPaused(true) }
            group.addTask { _ = try await store.move(second, by: -1, configuredFolders: [root], excludingAudioURL: nil) }
            try await group.waitForAll()
        }
        let saved = try await store.load()
        #expect(saved.paused)
        #expect(saved.order == [second.path, first.path])
        #expect(saved.knownFolders?.count == 21)
        #expect(try await QueueScheduleStore(url: store.url).load() == saved)
    }

    @Test(arguments: [Data("broken".utf8), Data(#"{"version":99,"paused":false,"order":[]}"#.utf8)])
    func invalidSchedulePreventsAllMutationsAndNewQueueIntent(bytes: Data) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"))
        try bytes.write(to: store.url)
        let audio = root.appendingPathComponent("audio.m4a")
        await #expect(throws: (any Error).self) { _ = try await store.setPaused(false) }
        await #expect(throws: (any Error).self) { try await store.rememberFolder(root) }
        await #expect(throws: (any Error).self) { try await store.saveItem(item(), for: audio) }
        #expect(try Data(contentsOf: store.url) == bytes)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("audio.queue.json").path))
    }

    @Test func snapshotPreservesMissingAudioAndFiltersActiveRecording() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"))
        let active = root.appendingPathComponent("active.wav")
        let missing = root.appendingPathComponent("missing.m4a")
        let present = root.appendingPathComponent("present.wav")
        let activeItem = item(), missingItem = item(), presentItem = item()
        for (audio, intent) in [(active, activeItem), (missing, missingItem), (present, presentItem)] {
            try await store.saveItem(intent, for: audio)
        }
        for audio in [active, present] { try Data("audio".utf8).write(to: audio) }
        let snapshot = try await store.snapshot(configuredFolders: [], excludingAudioURL: active)
        #expect(snapshot.items.count == 2)
        #expect(!snapshot.items.contains { $0.item.id == activeItem.id })
        let absent = try #require(snapshot.items.first { $0.item.id == missingItem.id })
        let available = try #require(snapshot.items.first { $0.item.id == presentItem.id })
        #expect(absent.fileSize == nil)
        #expect(available.fileSize == 5)
    }

    @Test func retiringAnOwnedMarkerRetainsAudioAndRejectsReplacement() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"))
        let audio = root.appendingPathComponent("audio.m4a")
        try Data("audio".utf8).write(to: audio)
        let original = item()
        try await store.saveItem(original, for: audio)
        await #expect(throws: (any Error).self) { try await store.retireItem(at: audio, expectedID: UUID()) }
        #expect(try await store.loadItem(for: audio)?.id == original.id)
        try await store.retireItem(at: audio, expectedID: original.id)
        try await store.retireItem(at: audio, expectedID: original.id) // Already retired is harmless.
        #expect(try await store.loadItem(for: audio) == nil)
        #expect(try Data(contentsOf: audio) == Data("audio".utf8))
    }

    @Test func saveRejectsUnreadableOrDifferentlyOwnedMarker() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"))
        let audio = root.appendingPathComponent("audio.m4a")
        let marker = root.appendingPathComponent("audio.queue.json")
        for bytes in [Data("corrupt".utf8), try JSONEncoder().encode(item())] {
            try bytes.write(to: marker)
            await #expect(throws: (any Error).self) { try await store.saveItem(item(), for: audio) }
            #expect(try Data(contentsOf: marker) == bytes)
        }
    }

    @Test func olderPauseRequestCannotOverwriteNewerSafetyPause() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"))
        _ = try await store.setPaused(true, revision: 2)
        _ = try await store.setPaused(false, revision: 1)
        #expect(try await store.load().paused)
        _ = try await store.setPaused(false, revision: 3)
        #expect(try await store.load().paused == false)
    }


    @Test(arguments: [false, true])
    func removalPreservesIntentChangedDuringRecoveryDismissal(sameIdentity: Bool) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"))
        let audio = root.appendingPathComponent("audio.m4a")
        let marker = root.appendingPathComponent("audio.queue.json")
        try Data("audio".utf8).write(to: audio)
        let original = item(auto: true)
        try await store.saveItem(original, for: audio)
        var changed = original
        changed.id = sameIdentity ? original.id : UUID()
        changed.tags = true
        let replacement = changed
        await #expect(throws: CocoaError.self) {
            try await store.removeQueuedItem(at: audio, dismiss: { id in
                #expect(id == original.id)
                #expect(try await store.loadItem(for: audio)?.autoQueued == false)
                if sameIdentity {
                    // A reentrant store invocation changes options while dismissal waits.
                    try await store.saveItem(replacement, for: audio)
                } else {
                    // A separately written marker may claim this path for a new job.
                    try JSONEncoder().encode(replacement).write(to: marker, options: .atomic)
                }
                _ = try await store.setPaused(true)
            })
        }
        let retained = try #require(try await store.loadItem(for: audio))
        #expect(retained.id == replacement.id && retained.tags && retained.autoQueued)
        #expect(try await store.load().paused)
        #expect(try Data(contentsOf: audio) == Data("audio".utf8))
    }

}
