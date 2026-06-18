import Testing
import Foundation
@testable import dBrief

private func person(_ id: String, _ name: String, _ embeddings: [[Float]]) -> KnownPerson {
    KnownPerson(id: id, name: name,
                voiceprints: embeddings.map { Voiceprint(embedding: $0, model: "t", capturedAt: Date(timeIntervalSince1970: 0)) })
}

struct SpeakerReviewCandidatesTests {
    @Test("Ranks people by best cosine, descending, capped to k")
    func ranking() {
        let lib = VoiceLibrary(people: [
            person("amy", "Amy", [[1, 0]]),          // cosine 1.0 with [1,0]
            person("bob", "Bob", [[0, 1]]),          // cosine 0.0
            person("cleo", "Cleo", [[1, 1], [0.9, 0.1]]), // best ~0.996
        ])
        let out = SpeakerReviewCandidates.topMatches(clusterEmbedding: [1, 0], library: lib, k: 2)
        #expect(out.count == 2)
        #expect(out[0].personId == "amy")
        #expect(out[1].personId == "cleo")
        #expect(out[0].score >= out[1].score)
    }

    @Test("Empty cluster embedding or empty library -> no candidates")
    func emptyInputs() {
        let lib = VoiceLibrary(people: [person("amy", "Amy", [[1, 0]])])
        #expect(SpeakerReviewCandidates.topMatches(clusterEmbedding: [], library: lib).isEmpty)
        #expect(SpeakerReviewCandidates.topMatches(clusterEmbedding: [1, 0], library: VoiceLibrary()).isEmpty)
    }
}
