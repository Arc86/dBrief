import Foundation
import Testing
@testable import dBrief

@Suite("VoiceIdentityResolver.resolve")
struct VoiceIdentityResolverTests {
    private func person(_ name: String, _ vecs: [[Float]]) -> KnownPerson {
        KnownPerson(id: name.lowercased(), name: name,
                    voiceprints: vecs.map { Voiceprint(embedding: $0, model: "t", capturedAt: Date(timeIntervalSince1970: 0)) })
    }
    private func lib(_ people: [KnownPerson]) -> VoiceLibrary { VoiceLibrary(version: 1, people: people) }

    @Test("Empty library → every cluster .emptyLibrary")
    func emptyLibrary() {
        let d = VoiceIdentityResolver.resolve(
            clusterEmbeddings: ["Speaker 1": [1, 0]], library: lib([]), roster: [])
        #expect(d["Speaker 1"]?.reason == .emptyLibrary)
        #expect(d["Speaker 1"]?.personId == nil)
    }

    @Test("Confident, well-separated match auto-labels")
    func confidentMatch() {
        let library = lib([person("Alice", [[1, 0]]), person("Bob", [[0, 1]])])
        let d = VoiceIdentityResolver.resolve(
            clusterEmbeddings: ["Speaker 1": [0.99, 0.14]], library: library, roster: [])
        let dec = d["Speaker 1"]
        #expect(dec?.reason == .matched)
        #expect(dec?.name == "Alice")
        #expect(dec?.personId == "alice")
    }

    @Test("Below threshold → .belowThreshold, no name")
    func belowThreshold() {
        let library = lib([person("Alice", [[1, 0]])])
        // cluster nearly orthogonal to Alice → low cosine
        let d = VoiceIdentityResolver.resolve(
            clusterEmbeddings: ["Speaker 1": [0.2, 0.98]], library: library, roster: [],
            minConfidence: 0.55, margin: 0.07)
        #expect(d["Speaker 1"]?.reason == .belowThreshold)
        #expect(d["Speaker 1"]?.name == nil)
    }

    @Test("Two near-equal candidates → .lowMargin")
    func lowMargin() {
        // Alice and Bob almost identical; cluster close to both → top ~ runner-up
        let library = lib([person("Alice", [[1, 0]]), person("Bob", [[0.999, 0.045]])])
        let d = VoiceIdentityResolver.resolve(
            clusterEmbeddings: ["Speaker 1": [1, 0]], library: library, roster: [], margin: 0.07)
        #expect(d["Speaker 1"]?.reason == .lowMargin)
    }

    @Test("Roster gate: off-roster top match cannot win")
    func rosterGate() {
        let library = lib([person("Alice", [[1, 0]]), person("Bob", [[0, 1]])])
        // cluster is clearly Alice, but roster only lists Bob
        let d = VoiceIdentityResolver.resolve(
            clusterEmbeddings: ["Speaker 1": [1, 0]], library: library, roster: ["Bob"])
        #expect(d["Speaker 1"]?.reason == .offRoster)
        #expect(d["Speaker 1"]?.name == nil)
    }

    @Test("One person per cluster — stronger cluster wins, other → .lostContention")
    func contention() {
        let library = lib([person("Alice", [[1, 0]])])
        let d = VoiceIdentityResolver.resolve(
            clusterEmbeddings: ["Speaker 1": [1, 0], "Speaker 2": [0.9, 0.2]],
            library: library, roster: [], minConfidence: 0.5, margin: 0.0)
        // Speaker 1 is the better Alice match
        #expect(d["Speaker 1"]?.reason == .matched)
        #expect(d["Speaker 1"]?.name == "Alice")
        #expect(d["Speaker 2"]?.reason == .lostContention)
        #expect(d["Speaker 2"]?.name == nil)
    }

    @Test("Cluster without an embedding → .noEmbedding")
    func noEmbedding() {
        let library = lib([person("Alice", [[1, 0]])])
        let d = VoiceIdentityResolver.resolve(
            clusterEmbeddings: ["Speaker 1": []], library: library, roster: [])
        #expect(d["Speaker 1"]?.reason == .noEmbedding)
    }

    @Test("Person score = max over voiceprints")
    func maxOverPrints() {
        // One bad print, one perfect print → should still match on the good one.
        let library = lib([person("Alice", [[0, 1], [1, 0]])])
        let d = VoiceIdentityResolver.resolve(
            clusterEmbeddings: ["Speaker 1": [1, 0]], library: library, roster: [])
        #expect(d["Speaker 1"]?.reason == .matched)
    }
}
