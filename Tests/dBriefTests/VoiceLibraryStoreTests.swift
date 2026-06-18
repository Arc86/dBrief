import Foundation
import Testing
@testable import dBrief

@Suite("VoiceLibraryStore")
struct VoiceLibraryStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voicelib-\(UUID().uuidString)")
            .appendingPathComponent("library.json")
    }
    private func print1(_ v: [Float]) -> Voiceprint {
        Voiceprint(embedding: v, model: "test", capturedAt: Date(timeIntervalSince1970: 1))
    }

    @Test("Load returns empty library when file absent")
    func loadAbsent() async {
        let store = VoiceLibraryStore(url: tempURL())
        let lib = await store.load()
        #expect(lib.people.isEmpty)
        #expect(lib.version == 1)
    }

    @Test("Save then load round-trips")
    func roundTrip() async {
        let store = VoiceLibraryStore(url: tempURL())
        var lib = VoiceLibrary()
        lib.people = [KnownPerson(id: "alice", name: "Alice", voiceprints: [print1([1, 2, 3])])]
        await store.save(lib)
        let back = await store.load()
        #expect(back.people.count == 1)
        #expect(back.people[0].name == "Alice")
        #expect(back.people[0].voiceprints[0].embedding == [1, 2, 3])
    }

    @Test("Upsert creates a person then appends to it (case-insensitive name key)")
    func upsertCreatesThenAppends() async {
        let store = VoiceLibraryStore(url: tempURL())
        await store.upsert(name: "Bob", voiceprint: print1([1]), maxPerPerson: 5)
        // dedupThreshold: 2 disables dedup (cosine never exceeds 1) so these
        // collinear single-element markers exercise append, not the dedup path.
        await store.upsert(name: "bob", voiceprint: print1([2]), maxPerPerson: 5, dedupThreshold: 2)
        let lib = await store.load()
        #expect(lib.people.count == 1)
        #expect(lib.people[0].voiceprints.count == 2)
        #expect(lib.people[0].name == "Bob") // first-seen display spelling kept
    }

    @Test("Upsert bounds voiceprints to maxPerPerson, dropping oldest")
    func upsertBounds() async {
        let store = VoiceLibraryStore(url: tempURL())
        // dedupThreshold: 2 disables dedup so the collinear [Float(i)] markers
        // all append, isolating the maxPerPerson bound behavior.
        for i in 0..<5 { await store.upsert(name: "Cara", voiceprint: print1([Float(i)]), maxPerPerson: 3, dedupThreshold: 2) }
        let lib = await store.load()
        #expect(lib.people[0].voiceprints.count == 3)
        #expect(lib.people[0].voiceprints.map { $0.embedding[0] } == [2, 3, 4]) // oldest dropped
    }

    @Test("Upsert returns the person id")
    func upsertReturnsId() async {
        let store = VoiceLibraryStore(url: tempURL())
        let id = await store.upsert(name: "  Dora ", voiceprint: print1([1, 0]))
        #expect(id == "dora")
    }

    @Test("Upsert skips a near-duplicate voiceprint, keeps a distinct one")
    func upsertDedups() async {
        let store = VoiceLibraryStore(url: tempURL())
        await store.upsert(name: "Eve", voiceprint: print1([1, 0]))
        await store.upsert(name: "Eve", voiceprint: print1([1, 0.01]))   // ~duplicate → skipped
        let lib = await store.load()
        #expect(lib.people[0].voiceprints.count == 1)
        await store.upsert(name: "Eve", voiceprint: print1([0, 1]))       // distinct → appended
        let lib2 = await store.load()
        #expect(lib2.people[0].voiceprints.count == 2)
    }
}
