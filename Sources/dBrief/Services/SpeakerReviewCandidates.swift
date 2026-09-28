import Foundation

/// Pure: rank known people by voiceprint similarity to a diarized cluster, for the
/// confirm-first review window's suggestion chips. Mirrors the resolver's per-person
/// scoring (max cosine over a person's prints) but returns the ranked list for display
/// rather than a single decision — so the resolver itself stays untouched.
enum SpeakerReviewCandidates {
    struct Choice: Identifiable, Equatable {
        let id: String
        let name: String
        let personId: String?
        let detail: String?
    }

    static func meetingChoices(names: [String], library: VoiceLibrary, search: String) -> [Choice] {
        PersonName.displayList(names).filter { matches($0, search: search) }.map { name in
            let people = library.people.filter {
                PersonName.display($0.name).caseInsensitiveCompare(name) == .orderedSame
            }
            // Equal names aren't enough to distinguish two separate library entries.
            let person = people.count == 1 ? people.first : nil
            return Choice(id: "meeting:" + name.lowercased(), name: name,
                          personId: person?.id, detail: person?.company)
        }
    }

    static func libraryChoices(library: VoiceLibrary, search: String, clusterEmbedding: [Float]) -> [Choice] {
        let scores = Dictionary(topMatches(clusterEmbedding: clusterEmbedding, library: library,
                                           k: library.people.count).map { ($0.personId, $0.score) },
                                uniquingKeysWith: { first, _ in first })
        return library.people.filter {
            matches($0.name, search: search) || matches($0.company ?? "", search: search)
        }.sorted {
            let left = scores[$0.id] ?? -1
            let right = scores[$1.id] ?? -1
            if left != right { return left > right }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.map { Choice(id: $0.id, name: $0.name, personId: $0.id, detail: $0.company) }
    }

    private static func matches(_ value: String, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || value.localizedStandardContains(query)
    }

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
