import Foundation

/// Pure: rank known people by voiceprint similarity to a diarized cluster, for the
/// confirm-first review window's suggestion chips. Mirrors the resolver's per-person
/// scoring (max cosine over a person's prints) but returns the ranked list for display
/// rather than a single decision — so the resolver itself stays untouched.
enum SpeakerReviewCandidates {
    struct Candidate: Equatable {
        let name: String
        let personId: String
        let score: Float
    }

    static func topMatches(clusterEmbedding: [Float], library: VoiceLibrary, k: Int = 3) -> [Candidate] {
        guard !clusterEmbedding.isEmpty, !library.people.isEmpty else { return [] }
        return library.people
            .map { p in
                let best = p.voiceprints.reduce(Float(-1)) {
                    max($0, VoiceMatch.cosineSimilarity(clusterEmbedding, $1.embedding))
                }
                return Candidate(name: p.name, personId: p.id, score: best)
            }
            .sorted { $0.score > $1.score }
            .prefix(k)
            .map { $0 }
    }
}
