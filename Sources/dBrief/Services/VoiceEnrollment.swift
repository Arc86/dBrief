import Foundation

/// Decides which diarized speakers are worth saving to the voice library:
/// those that have a real, user/participant-assigned display name (not the raw
/// "Speaker N" id) AND an extracted embedding.
enum VoiceEnrollment {
    struct Entry: Equatable {
        let name: String
        let embedding: [Float]
    }

    static func enrollable(speakerLabels: [SpeakerLabel], embeddings: [String: [Float]]) -> [Entry] {
        speakerLabels.compactMap { label in
            guard let embedding = embeddings[label.id] else { return nil }
            let name = label.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != label.id else { return nil }
            return Entry(name: name, embedding: embedding)
        }
    }

    /// True when `embedding` is a near-duplicate (cosine ≥ `threshold`) of any
    /// existing print. Used to avoid filling a person's bounded print set with
    /// near-identical vectors from the same voice/session, so the kept prints
    /// stay diverse and recognition keeps improving.
    static func isDuplicate(_ embedding: [Float], against existing: [Voiceprint], threshold: Float = 0.97) -> Bool {
        existing.contains { VoiceMatch.cosineSimilarity(embedding, $0.embedding) >= threshold }
    }
}
