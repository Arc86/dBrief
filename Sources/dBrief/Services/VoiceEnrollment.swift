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
}
