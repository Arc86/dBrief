import Foundation

/// A single speaker turn produced by a standalone diarization pass: which
/// speaker spoke, and the time range. Kept as our own `Sendable` type so the
/// SpeakerKit result types never leak past the transcription service.
struct DiarizedTurn: Sendable, Equatable {
    let speakerId: String   // e.g. "Speaker 1"
    let start: Double
    let end: Double
}
