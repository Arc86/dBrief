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
        var words: [Word]?

        init(
            start: Double,
            end: Double,
            text: String,
            words: [Word]? = nil
        ) {
            self.start = start
            self.end = end
            self.text = text
            self.words = words
        }
    }

    struct Word: Codable, Sendable {
        let word: String
        let start: Double
        let end: Double
        let probability: Double?

        init(word: String, start: Double, end: Double, probability: Double? = nil) {
            self.word = word
            self.start = start
            self.end = end
            self.probability = probability
        }
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
