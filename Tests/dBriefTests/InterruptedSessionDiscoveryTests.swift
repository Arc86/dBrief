import Foundation
import Testing
@testable import dBrief

@Suite("Interrupted session discovery")
struct InterruptedSessionDiscoveryTests {
    @Test
    func discoversRecoverableSessionsWithExistingTracksNewestFirst() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let older = InterruptedSessionManifest(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 100),
            state: .paused,
            tracks: [.init(kind: .microphone, relativePath: "mic.caf")]
        )
        let newer = InterruptedSessionManifest(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 200),
            state: .capturing,
            tracks: [.init(kind: .systemAudio, relativePath: "system.caf")]
        )
        try writeSession(older, named: "older", in: root, createTracks: true)
        try writeSession(newer, named: "newer", in: root, createTracks: true)

        let candidates = InterruptedSessionDiscovery.discover(in: root)

        #expect(candidates.map(\.manifest.id) == [newer.id, older.id])
        #expect(candidates.allSatisfy { $0.existingTrackURLs.count == 1 })
    }

    @Test
    func ignoresCompletedCorruptFutureAndMissingTrackSessions() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let completed = InterruptedSessionManifest(
            id: UUID(),
            startedAt: Date(),
            state: .completed,
            tracks: [.init(kind: .microphone, relativePath: "mic.caf")]
        )
        let future = InterruptedSessionManifest(
            version: InterruptedSessionManifest.currentVersion + 1,
            id: UUID(),
            startedAt: Date(),
            state: .paused,
            tracks: [.init(kind: .microphone, relativePath: "mic.caf")]
        )
        let missing = InterruptedSessionManifest(
            id: UUID(),
            startedAt: Date(),
            state: .finalizing,
            tracks: [.init(kind: .microphone, relativePath: "missing.caf")]
        )
        try writeSession(completed, named: "completed", in: root, createTracks: true)
        try writeSession(future, named: "future", in: root, createTracks: true)
        try writeSession(missing, named: "missing", in: root, createTracks: false)

        let corruptDirectory = root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: corruptDirectory.appendingPathComponent(InterruptedSessionManifest.fileName)
        )

        #expect(InterruptedSessionDiscovery.discover(in: root).isEmpty)
    }

    @Test
    func rejectsTrackPathsOutsideTheSessionDirectory() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideTrack = root.appendingPathComponent("outside.caf")
        try Data([0, 1, 2]).write(to: outsideTrack)

        let manifest = InterruptedSessionManifest(
            id: UUID(),
            startedAt: Date(),
            state: .capturing,
            tracks: [.init(kind: .microphone, relativePath: "../outside.caf")]
        )
        try writeSession(manifest, named: "traversal", in: root, createTracks: false)

        #expect(InterruptedSessionDiscovery.discover(in: root).isEmpty)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbrief-interrupted-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSession(
        _ manifest: InterruptedSessionManifest,
        named name: String,
        in root: URL,
        createTracks: Bool
    ) throws {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent(InterruptedSessionManifest.fileName),
            options: .atomic
        )
        if createTracks {
            for track in manifest.tracks {
                try Data([0, 1, 2]).write(to: directory.appendingPathComponent(track.relativePath))
            }
        }
    }
}
