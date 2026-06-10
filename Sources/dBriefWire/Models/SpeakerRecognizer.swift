import Foundation

/// Pure, dependency-free speaker recognition: given diarized turns that carry
/// voice embeddings and a set of known speakers (each a name + one or more
/// enrolled embeddings), decide which detected `speakerId`s correspond to known
/// people by cosine similarity.
///
/// Kept in `dBriefWire` with no ML dependencies so it is fully unit-testable and
/// shared by the app. Mirrors `SpeakerMerge`'s "pure helper" style.
public enum SpeakerRecognizer {

    /// A known person to match against. `centroid` is the mean of all the
    /// person's enrolled embeddings (already L2-comparable as produced by the
    /// diarizer's embedder).
    public struct KnownVoice: Sendable, Equatable {
        public let id: String      // stable library id (UUID string)
        public let name: String
        public let centroid: [Float]
        public init(id: String, name: String, centroid: [Float]) {
            self.id = id
            self.name = name
            self.centroid = centroid
        }
    }

    /// A resolved match for one detected speaker.
    public struct Match: Sendable, Equatable {
        public let knownId: String
        public let name: String
        public let score: Float    // cosine similarity in [-1, 1]
        public init(knownId: String, name: String, score: Float) {
            self.knownId = knownId
            self.name = name
            self.score = score
        }
    }

    /// For each detected `speakerId` present in `turns`, average that speaker's
    /// turn embeddings into a centroid and find the best-matching `KnownVoice`
    /// at or above `threshold`. Returns a map `speakerId -> Match`. Speakers with
    /// no embeddings, or no match above threshold, are omitted.
    ///
    /// - Parameter threshold: minimum cosine similarity to accept a match
    ///   (typical range 0.5–0.85; the app exposes this as a power-user setting).
    public static func match(
        turns: [DiarizedTurn],
        known: [KnownVoice],
        threshold: Float
    ) -> [String: Match] {
        guard !known.isEmpty else { return [:] }

        var result: [String: Match] = [:]
        for (speakerId, centroid) in speakerCentroids(from: turns) {
            var best: Match?
            for voice in known {
                let score = cosineSimilarity(centroid, voice.centroid)
                if score >= threshold, score > (best?.score ?? -Float.greatestFiniteMagnitude) {
                    best = Match(knownId: voice.id, name: voice.name, score: score)
                }
            }
            if let best { result[speakerId] = best }
        }
        return result
    }

    /// The centroid (mean embedding) for each `speakerId` in `turns`. Speakers
    /// whose turns carry no embeddings are skipped. Exposed so the enrollment
    /// flow can capture a single speaker's voiceprint from a diarization pass.
    public static func speakerCentroids(from turns: [DiarizedTurn]) -> [String: [Float]] {
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        for turn in turns {
            guard let emb = turn.embedding, !emb.isEmpty else { continue }
            if var running = sums[turn.speakerId] {
                guard running.count == emb.count else { continue } // dimension guard
                for i in running.indices { running[i] += emb[i] }
                sums[turn.speakerId] = running
            } else {
                sums[turn.speakerId] = emb
            }
            counts[turn.speakerId, default: 0] += 1
        }
        var centroids: [String: [Float]] = [:]
        for (id, sum) in sums {
            let n = Float(counts[id] ?? 1)
            centroids[id] = sum.map { $0 / n }
        }
        return centroids
    }

    /// Mean of a non-empty set of equal-length embeddings, or `nil` if empty or
    /// ragged. Used to fold enrolled samples into a single stored centroid.
    public static func centroid(of embeddings: [[Float]]) -> [Float]? {
        guard let first = embeddings.first, !first.isEmpty else { return nil }
        let dim = first.count
        var sum = [Float](repeating: 0, count: dim)
        var n = 0
        for emb in embeddings {
            guard emb.count == dim else { continue }
            for i in 0..<dim { sum[i] += emb[i] }
            n += 1
        }
        guard n > 0 else { return nil }
        return sum.map { $0 / Float(n) }
    }

    /// Cosine similarity of two equal-length vectors. Returns 0 when either is
    /// empty, dimensions differ, or a vector has zero magnitude.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }
}
