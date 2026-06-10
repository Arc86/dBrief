import Foundation
import dBriefWire
import Testing

struct SpeakerRecognizerTests {
    private func turn(_ id: String, _ start: Double, _ end: Double, _ embedding: [Float]?) -> DiarizedTurn {
        DiarizedTurn(speakerId: id, start: start, end: end, embedding: embedding)
    }

    @Test("cosine similarity: identical vectors are 1, orthogonal are 0")
    func cosineBasics() {
        #expect(abs(SpeakerRecognizer.cosineSimilarity([1, 0, 0], [1, 0, 0]) - 1) < 1e-6)
        #expect(abs(SpeakerRecognizer.cosineSimilarity([1, 0], [0, 1])) < 1e-6)
        // magnitude-invariant
        #expect(abs(SpeakerRecognizer.cosineSimilarity([2, 0], [5, 0]) - 1) < 1e-6)
        // mismatched dims / empty → 0
        #expect(SpeakerRecognizer.cosineSimilarity([1, 0], [1]) == 0)
        #expect(SpeakerRecognizer.cosineSimilarity([], []) == 0)
    }

    @Test("speakerCentroids averages a speaker's turn embeddings and skips empty")
    func centroids() {
        let turns = [
            turn("Speaker 1", 0, 1, [0, 2]),
            turn("Speaker 1", 1, 2, [2, 0]),
            turn("Speaker 2", 2, 3, nil),       // no embedding → skipped
        ]
        let c = SpeakerRecognizer.speakerCentroids(from: turns)
        #expect(c["Speaker 1"] == [1, 1])
        #expect(c["Speaker 2"] == nil)
    }

    @Test("centroid(of:) returns nil for empty/ragged input")
    func centroidGuards() {
        #expect(SpeakerRecognizer.centroid(of: []) == nil)
        #expect(SpeakerRecognizer.centroid(of: [[]]) == nil)
        #expect(SpeakerRecognizer.centroid(of: [[1, 1], [3, 3]]) == [2, 2])
    }

    @Test("match resolves the closest known voice above threshold")
    func matchAboveThreshold() {
        let known = [
            SpeakerRecognizer.KnownVoice(id: "alice", name: "Alice", centroid: [1, 0]),
            SpeakerRecognizer.KnownVoice(id: "bob", name: "Bob", centroid: [0, 1]),
        ]
        let turns = [turn("Speaker 1", 0, 5, [0.95, 0.05])]
        let m = SpeakerRecognizer.match(turns: turns, known: known, threshold: 0.7)
        #expect(m["Speaker 1"]?.name == "Alice")
        #expect(m["Speaker 1"]?.knownId == "alice")
    }

    @Test("match omits speakers below threshold")
    func matchBelowThreshold() {
        let known = [SpeakerRecognizer.KnownVoice(id: "alice", name: "Alice", centroid: [1, 0])]
        let turns = [turn("Speaker 1", 0, 5, [0.6, 0.8])] // cosine ~0.6 with [1,0]
        let m = SpeakerRecognizer.match(turns: turns, known: known, threshold: 0.7)
        #expect(m["Speaker 1"] == nil)
    }

    @Test("match with empty library or no embeddings yields nothing")
    func matchDegenerate() {
        let turns = [turn("Speaker 1", 0, 5, [1, 0])]
        #expect(SpeakerRecognizer.match(turns: turns, known: [], threshold: 0.5).isEmpty)
        let known = [SpeakerRecognizer.KnownVoice(id: "a", name: "A", centroid: [1, 0])]
        let noEmb = [turn("Speaker 1", 0, 5, nil)]
        #expect(SpeakerRecognizer.match(turns: noEmb, known: known, threshold: 0.5).isEmpty)
    }

    @Test("DiarizedTurn without embedding decodes (back-compat)")
    func backwardCompatDecoding() throws {
        let legacy = #"{"speakerId":"Speaker 1","start":0,"end":1}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DiarizedTurn.self, from: legacy)
        #expect(decoded.speakerId == "Speaker 1")
        #expect(decoded.embedding == nil)
    }
}
