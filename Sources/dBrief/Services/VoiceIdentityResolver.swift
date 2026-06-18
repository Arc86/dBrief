import Foundation

/// Pure speaker→known-person matching. No IO, no ML. Consumes per-cluster
/// voiceprints (from the Phase 1 embedding pass), a `VoiceLibrary` snapshot, and
/// a roster of likely-present names. Mirrors `CalendarMatcher`'s pure-helper
/// style; fully unit-testable without CoreML.
///
/// Rules:
///  - **Person score** = max cosine over that person's voiceprints (cosine is
///    magnitude-invariant, so non-unit-norm embeddings compare fine).
///  - **Roster gate** (hard, only when the roster is non-empty): only people on
///    the roster are eligible for a confident match; an off-roster top match is
///    downgraded to `.offRoster`.
///  - **Margin gate**: the top eligible person must beat the runner-up eligible
///    person by `margin`, else `.lowMargin`.
///  - **Contention**: one person per cluster, one cluster per person — resolved
///    greedily by descending confidence; the loser becomes `.lostContention`.
enum VoiceIdentityResolver {
    enum Reason: String, Equatable, Sendable {
        case matched          // confident, auto-labeled
        case belowThreshold   // top score < minConfidence
        case lowMargin        // top didn't beat runner-up by margin
        case offRoster        // top person not on the (non-empty) roster
        case lostContention   // a higher-confidence cluster claimed this person
        case noEmbedding      // cluster has no usable voiceprint
        case emptyLibrary     // library has no people
    }

    struct Decision: Equatable, Sendable {
        let speakerId: String
        let personId: String?   // non-nil only when reason == .matched
        let name: String?       // matched person's display name (reason == .matched)
        let confidence: Float   // best eligible cosine (0 when none)
        let reason: Reason
    }

    static let defaultMinConfidence: Float = 0.55
    static let defaultMargin: Float = 0.07

    /// Resolves each speaker cluster to a known person, or leaves it uncertain.
    /// `roster` are names likely present (participants + calendar attendees);
    /// when non-empty it gates the eligible people.
    static func resolve(
        clusterEmbeddings: [String: [Float]],
        library: VoiceLibrary,
        roster: [String],
        minConfidence: Float = defaultMinConfidence,
        margin: Float = defaultMargin
    ) -> [String: Decision] {
        let clusters = clusterEmbeddings.keys.sorted()

        guard !library.people.isEmpty else {
            return Dictionary(uniqueKeysWithValues: clusters.map {
                ($0, Decision(speakerId: $0, personId: nil, name: nil, confidence: 0, reason: .emptyLibrary))
            })
        }

        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let rosterKeys = Set(roster.map(norm).filter { !$0.isEmpty })
        func eligible(_ p: KnownPerson) -> Bool {
            rosterKeys.isEmpty || rosterKeys.contains(norm(p.name))
        }
        func personScore(_ emb: [Float], _ p: KnownPerson) -> Float {
            p.voiceprints.reduce(Float(-1)) { max($0, VoiceMatch.cosineSimilarity(emb, $1.embedding)) }
        }

        // Per-cluster scoring.
        struct ClusterScore {
            var bestEligible: (person: KnownPerson, score: Float)?
            var runnerUpEligible: Float
            var topAnyOffRoster: Bool
            var hasEmb: Bool
        }
        var scores: [String: ClusterScore] = [:]
        for c in clusters {
            let emb = clusterEmbeddings[c] ?? []
            guard emb.contains(where: { $0 != 0 }) else {
                scores[c] = ClusterScore(bestEligible: nil, runnerUpEligible: -1, topAnyOffRoster: false, hasEmb: false)
                continue
            }
            let scored = library.people.map { (person: $0, score: personScore(emb, $0)) }
            let eligibleScored = scored.filter { eligible($0.person) }.sorted { $0.score > $1.score }
            let best = eligibleScored.first
            let runnerUp = eligibleScored.dropFirst().first?.score ?? -1
            let topAny = scored.max { $0.score < $1.score }
            let topAnyOffRoster = !rosterKeys.isEmpty && topAny.map { !eligible($0.person) } == true
            scores[c] = ClusterScore(
                bestEligible: best.map { (person: $0.person, score: $0.score) },
                runnerUpEligible: runnerUp,
                topAnyOffRoster: topAnyOffRoster,
                hasEmb: true)
        }

        // Greedy contention: assign highest-confidence eligible matches first.
        var triples: [(c: String, p: KnownPerson, s: Float)] = []
        for c in clusters {
            if let b = scores[c]?.bestEligible, b.score >= minConfidence {
                triples.append((c, b.person, b.score))
            }
        }
        triples.sort {
            $0.s != $1.s ? $0.s > $1.s : ($0.c != $1.c ? $0.c < $1.c : $0.p.id < $1.p.id)
        }

        var decisions: [String: Decision] = [:]
        var takenPeople = Set<String>()
        for t in triples {
            guard decisions[t.c] == nil, !takenPeople.contains(t.p.id) else { continue }
            let cs = scores[t.c]!
            // Only the cluster's best-eligible person may win, and it must clear the margin.
            guard cs.bestEligible?.person.id == t.p.id, (t.s - cs.runnerUpEligible) >= margin else { continue }
            takenPeople.insert(t.p.id)
            decisions[t.c] = Decision(speakerId: t.c, personId: t.p.id, name: t.p.name, confidence: t.s, reason: .matched)
        }

        // Fill in the most specific uncertain reason for unmatched clusters.
        for c in clusters where decisions[c] == nil {
            let cs = scores[c]!
            let conf = cs.bestEligible?.score ?? 0
            let reason: Reason
            if !cs.hasEmb {
                reason = .noEmbedding
            } else if cs.bestEligible == nil || (cs.topAnyOffRoster && conf < minConfidence) {
                reason = .offRoster
            } else if conf < minConfidence {
                reason = .belowThreshold
            } else if (conf - cs.runnerUpEligible) < margin {
                reason = .lowMargin
            } else {
                reason = .lostContention
            }
            decisions[c] = Decision(speakerId: c, personId: nil, name: nil, confidence: max(0, conf), reason: reason)
        }
        return decisions
    }
}
