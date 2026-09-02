import Foundation
import Testing
@testable import dBrief

@Suite("Interrupted session store")
struct InterruptedSessionStoreTests {
    @Test
    func createsManifestBeforeCaptureWithDeterministicTrackPaths() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_234)

        let session = try InterruptedSessionStore.createSession(
            id: id,
            startedAt: startedAt,
            rootURL: root
        )

        #expect(FileManager.default.fileExists(atPath: session.manifestURL.path))
        #expect(!FileManager.default.fileExists(atPath: session.captureBaseURL.path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            InterruptedSessionManifest.self,
            from: Data(contentsOf: session.manifestURL)
        )
        #expect(manifest.id == id)
        #expect(manifest.state == .capturing)
        #expect(Set(manifest.tracks.map(\.relativePath)) == ["capture.mic.caf", "capture.system.caf"])
    }

    @Test
    func stateUpdatePersistsAndRemovalDeletesOnlyTheSessionDirectory() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sibling = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sibling)
        let session = try InterruptedSessionStore.createSession(
            id: UUID(),
            startedAt: Date(),
            rootURL: root
        )

        let updated = try InterruptedSessionStore.updateState(
            at: session.manifestURL,
            to: .paused
        )
        #expect(updated.state == .paused)

        try InterruptedSessionStore.removeSession(
            containing: session.manifestURL,
            finalState: .discarded
        )
        #expect(!FileManager.default.fileExists(atPath: session.directoryURL.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dbrief-session-store-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
