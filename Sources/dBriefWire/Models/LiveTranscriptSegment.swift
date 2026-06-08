import Foundation

public struct LiveTranscriptSegment: Identifiable, Sendable, Codable {
    public let id = UUID()
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case start, end, text }
}
