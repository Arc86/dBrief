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

    @Test("Upsert returns a non-empty id and rejects a blank name")
    func upsertReturnsId() async {
        let store = VoiceLibraryStore(url: tempURL())
        let id = await store.upsert(name: "  Dora ", voiceprint: print1([1, 0]))
        #expect(!id.isEmpty)
        let blank = await store.upsert(name: "   ", voiceprint: print1([1, 0]))
        #expect(blank == "")
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

    @Test("Upsert mints a stable id for a new name and reuses it on re-upsert")
    func upsertStableId() async {
        let store = VoiceLibraryStore(url: tempURL())
        let id1 = await store.upsert(name: "Dora", voiceprint: print1([1, 0]))
        let id2 = await store.upsert(name: "dora", voiceprint: print1([0, 1]), dedupThreshold: 2)
        #expect(id1 == id2)            // same person, id reused (case-insensitive)
        #expect(!id1.isEmpty)
        let lib = await store.load()
        #expect(lib.people.count == 1)
        #expect(lib.people[0].id == id1)
    }

    @Test("Rename changes the name but keeps the id stable")
    func renameKeepsId() async {
        let store = VoiceLibraryStore(url: tempURL())
        let id = await store.upsert(name: "Bob", voiceprint: print1([1, 0]))
        let outcome = await store.rename(id: id, to: "Robert")
        #expect(outcome == .renamed)
        let lib = await store.load()
        #expect(lib.people.count == 1)
        #expect(lib.people[0].id == id)        // unchanged
        #expect(lib.people[0].name == "Robert")
    }

    @Test("Rename to an absent id reports notFound")
    func renameNotFound() async {
        let store = VoiceLibraryStore(url: tempURL())
        let outcome = await store.rename(id: "nope", to: "X")
        #expect(outcome == .notFound)
    }

    @Test("Rename onto another person's name reports collision and changes nothing")
    func renameCollision() async {
        let store = VoiceLibraryStore(url: tempURL())
        let bobId = await store.upsert(name: "Bob", voiceprint: print1([1, 0]))
        let amyId = await store.upsert(name: "Amy", voiceprint: print1([0, 1]))
        let outcome = await store.rename(id: amyId, to: "bob")    // case-insensitive collide
        #expect(outcome == .collision(existingId: bobId))
        let lib = await store.load()
        #expect(lib.people.first(where: { $0.id == amyId })?.name == "Amy")  // untouched
    }

    @Test("Merge combines voiceprints into the survivor and drops the source")
    func mergeCombines() async {
        let store = VoiceLibraryStore(url: tempURL())
        let keepId = await store.upsert(name: "Keep", voiceprint: print1([1, 0]))
        let dropId = await store.upsert(name: "Drop", voiceprint: print1([0, 1]))
        let ok = await store.merge(sourceId: dropId, into: keepId, dedupThreshold: 2)
        #expect(ok)
        let lib = await store.load()
        #expect(lib.people.count == 1)
        #expect(lib.people[0].id == keepId)
        #expect(lib.people[0].voiceprints.count == 2)
    }

    @Test("Merge dedups and bounds to maxPerPerson")
    func mergeBoundsAndDedups() async {
        let store = VoiceLibraryStore(url: tempURL())
        let keepId = await store.upsert(name: "Keep", voiceprint: print1([1, 0]), dedupThreshold: 2)
        await store.upsert(name: "Keep", voiceprint: print1([2, 0]), dedupThreshold: 2)
        let dropId = await store.upsert(name: "Drop", voiceprint: print1([1, 0]))   // ~dup of keep's first
        await store.upsert(name: "Drop", voiceprint: print1([0, 5]), dedupThreshold: 2)
        let ok = await store.merge(sourceId: dropId, into: keepId, maxPerPerson: 3, dedupThreshold: 0.97)
        #expect(ok)
        let lib = await store.load()
        #expect(lib.people.count == 1)
        #expect(lib.people[0].voiceprints.count <= 3)   // bounded; near-dup skipped
    }

    @Test("Merge is a no-op for equal ids or a missing id")
    func mergeNoop() async {
        let store = VoiceLibraryStore(url: tempURL())
        let id = await store.upsert(name: "Solo", voiceprint: print1([1, 0]))
        #expect(await store.merge(sourceId: id, into: id) == false)
        #expect(await store.merge(sourceId: "ghost", into: id) == false)
    }

    @Test("Delete removes the person")
    func deletePerson() async {
        let store = VoiceLibraryStore(url: tempURL())
        let id = await store.upsert(name: "Gone", voiceprint: print1([1, 0]))
        #expect(await store.delete(id: id))
        #expect(await store.load().people.isEmpty)
        #expect(await store.delete(id: id) == false)   // already gone
    }

    @Test("removeVoiceprint drops one sample; removing the last drops the person")
    func removeVoiceprint() async {
        let store = VoiceLibraryStore(url: tempURL())
        // Two prints with distinct capturedAt so we can target one.
        var lib = VoiceLibrary()
        let early = Voiceprint(embedding: [1, 0], model: "t", capturedAt: Date(timeIntervalSince1970: 1))
        let late = Voiceprint(embedding: [0, 1], model: "t", capturedAt: Date(timeIntervalSince1970: 2))
        lib.people = [KnownPerson(id: "p", name: "Pat", voiceprints: [early, late])]
        await store.save(lib)
        #expect(await store.removeVoiceprint(personId: "p", capturedAt: early.capturedAt))
        let after = await store.load()
        #expect(after.people[0].voiceprints.count == 1)
        #expect(after.people[0].voiceprints[0].capturedAt == late.capturedAt)
        #expect(await store.removeVoiceprint(personId: "p", capturedAt: late.capturedAt))
        #expect(await store.load().people.isEmpty)   // last sample → person removed
    }

    @Test("setCompany sets, trims, and clears to nil on empty")
    func setCompanyTrimsAndClears() async {
        let store = VoiceLibraryStore(url: tempURL())
        let id = await store.upsert(name: "Alice", voiceprint: print1([1]))
        await store.setCompany(id: id, to: "  Acme  ")
        #expect(await store.load().people.first(where: { $0.id == id })?.company == "Acme")
        await store.setCompany(id: id, to: "   ")
        #expect(await store.load().people.first(where: { $0.id == id })?.company == nil)
    }

    @Test("suggestCompanyIfEmpty fills only when empty, never overwrites")
    func suggestFillOnly() async {
        let store = VoiceLibraryStore(url: tempURL())
        let id = await store.upsert(name: "Bob", voiceprint: print1([1]))
        #expect(await store.suggestCompanyIfEmpty(id: id, to: "Acme") == true)
        #expect(await store.load().people.first(where: { $0.id == id })?.company == "Acme")
        #expect(await store.suggestCompanyIfEmpty(id: id, to: "Globex") == false)
        #expect(await store.load().people.first(where: { $0.id == id })?.company == "Acme")
    }

    @Test("old libraries without company decode with nil")
    func lenientDecode() throws {
        let json = #"{"version":1,"people":[{"id":"x","name":"Carol","voiceprints":[]}]}"#
        let lib = try JSONDecoder().decode(VoiceLibrary.self, from: Data(json.utf8))
        #expect(lib.people.first?.company == nil)
    }
}
