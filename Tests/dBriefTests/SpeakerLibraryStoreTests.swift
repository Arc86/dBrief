import Foundation
import Testing
@testable import dBrief

struct SpeakerLibraryStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dbrief-speakers-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("speaker-library.json")
    }

    @Test("missing file loads as an empty library")
    func emptyOnMissing() async {
        let store = SpeakerLibraryStore(fileURL: tempURL())
        let lib = await store.load()
        #expect(lib.speakers.isEmpty)
    }

    @Test("enroll creates then appends samples to the same name")
    func enrollRoundTrip() async throws {
        let url = tempURL()
        let store = SpeakerLibraryStore(fileURL: url)
        try await store.enroll(name: "Alice", embedding: [1, 0])
        var lib = try await store.enroll(name: "alice", embedding: [0, 1]) // same name, case-insensitive
        #expect(lib.speakers.count == 1)
        #expect(lib.speakers[0].sampleCount == 2)
        #expect(lib.speakers[0].centroid == [0.5, 0.5])

        // Persisted across a fresh store instance pointed at the same file.
        let reopened = SpeakerLibraryStore(fileURL: url)
        lib = await reopened.load()
        #expect(lib.speakers.count == 1)
        #expect(lib.speakers[0].name == "Alice")
    }

    @Test("file is written with 0600 permissions")
    func securePermissions() async throws {
        let url = tempURL()
        let store = SpeakerLibraryStore(fileURL: url)
        try await store.enroll(name: "Bob", embedding: [1, 1])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
    }

    @Test("rename, delete, and forgetAll")
    func mutations() async throws {
        let url = tempURL()
        let store = SpeakerLibraryStore(fileURL: url)
        var lib = try await store.enroll(name: "Carol", embedding: [1, 0])
        let id = lib.speakers[0].id

        lib = try await store.rename(id: id, to: "Caroline")
        #expect(lib.speakers[0].name == "Caroline")

        lib = try await store.delete(id: id)
        #expect(lib.speakers.isEmpty)

        try await store.enroll(name: "Dave", embedding: [0, 1])
        try await store.forgetAll()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await store.load().speakers.isEmpty)
    }
}
