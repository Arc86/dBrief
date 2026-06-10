import Foundation
import dBriefWire

/// On-device library of known people for speaker recognition. Persisted as a
/// single global `speaker-library.json` under Application Support — never inside
/// per-recording sidecars, so voiceprints stay in exactly one place the user can
/// inspect and purge.
struct SpeakerLibrary: Codable, Sendable {
    var version: Int = 1
    var speakers: [KnownSpeaker] = []
}

/// One enrolled person. Holds the name plus one or more voice embeddings
/// (samples) captured from named speaker turns; multiple samples make the
/// matching centroid more robust over time. Embeddings are one-way vectors
/// produced by the diarizer's embedder — not recoverable audio.
struct KnownSpeaker: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var embeddings: [[Float]]
    var createdAt: Date = Date()
    var lastSeenAt: Date?

    var sampleCount: Int { embeddings.count }

    /// Mean of the enrolled samples — the vector matching compares against.
    var centroid: [Float] { SpeakerRecognizer.centroid(of: embeddings) ?? [] }

    /// Cap on stored samples per person; keeps the file bounded and matching
    /// cheap. New samples evict the oldest beyond this.
    static let maxSamples = 12

    /// As the pure `SpeakerRecognizer.KnownVoice` used by matching.
    var knownVoice: SpeakerRecognizer.KnownVoice? {
        let c = centroid
        return c.isEmpty ? nil : SpeakerRecognizer.KnownVoice(id: id.uuidString, name: name, centroid: c)
    }
}
