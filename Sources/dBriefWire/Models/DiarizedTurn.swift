import Foundation

/// A single speaker turn produced by a standalone diarization pass: which
/// speaker spoke, and the time range. Kept as our own `Sendable` type so the
/// SpeakerKit result types never leak past the transcription service.
public struct DiarizedTurn: Sendable, Equatable, Codable {
    public let speakerId: String   // e.g. "Speaker 1"
    public let start: Double
    public let end: Double
    /// Voice embedding (voiceprint) for this turn, when the diarizer produced
    /// one. Populated only by the FluidAudio embedding pass used for speaker
    /// recognition; the SpeakerKit pass leaves it `nil`. Optional with a default
    /// so older JSON (without the field) still decodes.
    public var embedding: [Float]?

    public init(speakerId: String, start: Double, end: Double, embedding: [Float]? = nil) {
        self.speakerId = speakerId
        self.start = start
        self.end = end
        self.embedding = embedding
    }
}
