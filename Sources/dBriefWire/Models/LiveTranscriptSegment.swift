import Foundation

public struct LiveTranscriptSegment: Identifiable, Sendable, Codable {
    public let id = UUID()
    public let start: Double
    public let end: Double
    public let text: String
    /// Speaker label for live two-channel transcription (e.g. "You" / "Participant").
    /// `nil` for single-channel post-recording WhisperKit live segments.
    public let speaker: String?

    public init(start: Double, end: Double, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }

    private enum CodingKeys: String, CodingKey { case start, end, text, speaker }
}
