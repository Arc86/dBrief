import Foundation

/// Voiceprint comparison primitives. (Phase 1 ships only the similarity
/// function; identity resolution that consumes it lands in Phase 2.)
enum VoiceMatch {
    /// Cosine similarity of two equal-length embedding vectors, in [-1, 1].
    /// Returns 0 when the vectors differ in length, are empty, or either has
    /// zero magnitude.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom == 0 ? 0 : dot / denom
    }
}
