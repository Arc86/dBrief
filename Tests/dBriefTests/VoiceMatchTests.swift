import Foundation
import Testing
@testable import dBrief

@Suite("VoiceMatch.cosineSimilarity")
struct VoiceMatchTests {
    @Test("Identical vectors → ~1")
    func identical() {
        let v: [Float] = [1, 2, 3, 4]
        #expect(abs(VoiceMatch.cosineSimilarity(v, v) - 1) < 1e-5)
    }

    @Test("Orthogonal vectors → 0")
    func orthogonal() {
        #expect(abs(VoiceMatch.cosineSimilarity([1, 0], [0, 1])) < 1e-6)
    }

    @Test("Opposite vectors → ~-1")
    func opposite() {
        #expect(abs(VoiceMatch.cosineSimilarity([1, 1], [-1, -1]) + 1) < 1e-5)
    }

    @Test("Length mismatch or zero vector → 0")
    func degenerate() {
        #expect(VoiceMatch.cosineSimilarity([1, 2, 3], [1, 2]) == 0)
        #expect(VoiceMatch.cosineSimilarity([0, 0], [1, 1]) == 0)
        #expect(VoiceMatch.cosineSimilarity([], []) == 0)
    }
}
