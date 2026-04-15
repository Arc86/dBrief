import Foundation

struct TranscriptionResult: Codable, Sendable {
    let text: String
    let segments: [Segment]
    let language: String?
    let warnings: [String]?
    let speakerCount: Int?

    struct Segment: Codable, Sendable {
        let start: Double
        let end: Double
        let text: String
        var words: [Word]?
        var speaker: String?

        init(
            start: Double,
            end: Double,
            text: String,
            words: [Word]? = nil,
            speaker: String? = nil
        ) {
            self.start = start
            self.end = end
            self.text = text
            self.words = words
            self.speaker = speaker
        }
    }

    struct Word: Codable, Sendable {
        let word: String
        let start: Double
        let end: Double
        let probability: Double?
        var speaker: String?

        init(word: String, start: Double, end: Double, probability: Double? = nil, speaker: String? = nil) {
            self.word = word
            self.start = start
            self.end = end
            self.probability = probability
            self.speaker = speaker
        }
    }

    init(
        text: String,
        segments: [Segment] = [],
        language: String? = nil,
        warnings: [String]? = nil,
        speakerCount: Int? = nil
    ) {
        self.text = text
        self.segments = segments
        self.language = language
        self.warnings = warnings
        self.speakerCount = speakerCount
    }

    var textForLLM: String {
        if segments.isEmpty {
            return text.replacingOccurrences(of: #"\*\*\[\d{2}:\d{2}:\d{2}\]\*\*"#, with: "", options: .regularExpression)
        }
        let hasSpeakerInfo = segments.contains { $0.speaker != nil }
        if hasSpeakerInfo {
            return segments.map { segment in
                if let speaker = segment.speaker {
                    return "\(speaker): \(segment.text)"
                }
                return segment.text
            }.joined(separator: "\n")
        }
        return segments.map { $0.text }.joined(separator: " ")
    }
}
