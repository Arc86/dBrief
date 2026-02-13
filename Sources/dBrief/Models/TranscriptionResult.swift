import Foundation

struct TranscriptionResult: Codable, Sendable {
    let text: String
    let segments: [Segment]
    let language: String?
    let warnings: [String]?

    struct Segment: Codable, Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    init(
        text: String,
        segments: [Segment] = [],
        language: String? = nil,
        warnings: [String]? = nil
    ) {
        self.text = text
        self.segments = segments
        self.language = language
        self.warnings = warnings
    }
}
