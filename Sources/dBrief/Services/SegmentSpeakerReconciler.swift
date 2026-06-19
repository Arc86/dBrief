import Foundation
import dBriefWire

/// Reconciles speakers across independently-diarized segments of a long
/// recording. Each 30-minute part is diarized on its own, so part 1's
/// "Speaker 1" and part 2's "Speaker 1" are not necessarily the same person.
/// This helper folds every part's *local* speaker ids into a single *global*
/// speaker space using voiceprint cosine similarity, so the merged transcript
/// has one consistent set of "Speaker N" labels plus one embedding per speaker.
///
/// Pure and deterministic. Degrades gracefully: a part with no embeddings (or a
/// speaker below the match threshold) contributes new distinct globals rather
/// than risk a wrong label — consistent with the project's "neutral Speaker N
/// beats a confident wrong name" stance.
enum SegmentSpeakerReconciler {
    /// Cross-part same-speaker acceptance threshold. Observed cross-speaker
    /// cosine ≈ 0.28 and self ≈ 1.0; all parts share one recording/mic/session,
    /// so same-speaker cosine across parts is high. 0.5 sits well between.
    static let matchThreshold: Float = 0.5

    struct Part {
        let segments: [TranscriptionResult.Segment]
        let speakerEmbeddings: [String: [Float]]?
        init(segments: [TranscriptionResult.Segment], speakerEmbeddings: [String: [Float]]?) {
            self.segments = segments
            self.speakerEmbeddings = speakerEmbeddings
        }
    }

    struct Result {
        let remaps: [[String: String]]
        let speakerEmbeddings: [String: [Float]]
        let speakerCount: Int
    }

    private struct Global {
        var id: String
        var vectors: [[Float]]   // contributing embeddings (empty if seeded without one)
        var rep: [Float]?        // running mean of `vectors`, nil when none
    }

    static func reconcile(_ parts: [Part]) -> Result {
        var globals: [Global] = []
        var remaps: [[String: String]] = []

        for part in parts {
            // Local speaker ids present in this part's segments, in sort order.
            let localIds = Set(part.segments.compactMap { $0.speaker }).sorted()
            var remap: [String: String] = [:]

            // 1. Greedy one-to-one match for locals that have an embedding.
            let embeds = part.speakerEmbeddings ?? [:]
            let embeddedLocals = localIds.filter { embeds[$0] != nil }

            // Candidate (local, globalIndex, cosine) pairs, only globals with a rep.
            var candidates: [(local: String, gIndex: Int, score: Float)] = []
            for local in embeddedLocals {
                guard let v = embeds[local] else { continue }
                for (gi, g) in globals.enumerated() {
                    guard let rep = g.rep else { continue }
                    candidates.append((local, gi, VoiceMatch.cosineSimilarity(v, rep)))
                }
            }
            // Sort by score desc; stable tiebreak on (globalId, localId) for determinism.
            candidates.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                if globals[$0.gIndex].id != globals[$1.gIndex].id {
                    return globals[$0.gIndex].id < globals[$1.gIndex].id
                }
                return $0.local < $1.local
            }
            var usedLocals: Set<String> = []
            var usedGlobals: Set<Int> = []
            for c in candidates {
                guard c.score >= matchThreshold else { break } // sorted desc → rest are lower
                guard !usedLocals.contains(c.local), !usedGlobals.contains(c.gIndex) else { continue }
                usedLocals.insert(c.local)
                usedGlobals.insert(c.gIndex)
                remap[c.local] = globals[c.gIndex].id
                globals[c.gIndex].vectors.append(embeds[c.local]!)
                globals[c.gIndex].rep = mean(globals[c.gIndex].vectors)
            }

            // 2. Every unmatched local (no embedding, below threshold, or lost
            //    contention) becomes a new global, in local-id sort order.
            for local in localIds where remap[local] == nil {
                let newId = "Speaker \(globals.count + 1)"
                var g = Global(id: newId, vectors: [], rep: nil)
                if let v = embeds[local] {
                    g.vectors = [v]
                    g.rep = v
                }
                globals.append(g)
                remap[local] = newId
            }

            remaps.append(remap)
        }

        var embeddings: [String: [Float]] = [:]
        for g in globals {
            if let rep = g.rep { embeddings[g.id] = rep }
        }
        return Result(remaps: remaps, speakerEmbeddings: embeddings, speakerCount: globals.count)
    }

    private static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        guard vectors.count > 1 else { return first }
        var acc = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == first.count {
            for i in v.indices { acc[i] += v[i] }
        }
        let n = Float(vectors.count)
        return acc.map { $0 / n }
    }
}
