import Foundation

/// A single speaker turn produced by a standalone diarization pass: which
/// speaker spoke, and the time range. Kept as our own `Sendable` type so the
/// SpeakerKit result types never leak past the transcription service.
public struct DiarizedTurn: Sendable, Equatable, Codable {
    public let speakerId: String   // e.g. "Speaker 1"
    public let start: Double
    public let end: Double

    public init(speakerId: String, start: Double, end: Double) {
        self.speakerId = speakerId
        self.start = start
        self.end = end
    }
}
