import Foundation

/// Pure: choose a short, representative audio range for a diarized speaker so the
/// confirm-first review window can play a sample of that voice. Picks the speaker's
/// single longest turn (most likely clean, contiguous speech) and caps it to
/// `maxLength` seconds from its start.
enum SpeakerSnippet {
    static func representative(for speakerId: String, in transcript: RichTranscript, maxLength: Double = 6) -> (start: Double, end: Double)? {
        guard let s = longestTurn(for: speakerId, in: transcript) else { return nil }
        let end = min(s.end, s.start + maxLength)
        return (s.start, end)
    }

    /// What the speaker says in that same turn, so a voice can be recognised without playing it.
    static func quote(for speakerId: String, in transcript: RichTranscript) -> String? {
        let text = longestTurn(for: speakerId, in: transcript)?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private static func longestTurn(for speakerId: String, in transcript: RichTranscript) -> RichSegment? {
        transcript.segments
            .filter { $0.speakerId == speakerId && $0.end > $0.start }
            .max { ($0.end - $0.start) < ($1.end - $1.start) }
    }
}
