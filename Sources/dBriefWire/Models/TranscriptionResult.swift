import Foundation

public struct TranscriptionResult: Codable, Sendable {
    public let text: String
    public let segments: [Segment]
    public let language: String?
    public let warnings: [String]?
    public let speakerCount: Int?

    public struct Segment: Codable, Sendable {
        public let start: Double
        public let end: Double
        public let text: String
        public var words: [Word]?
        public var speaker: String?

        public init(
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

    public struct Word: Codable, Sendable {
        public let word: String
        public let start: Double
        public let end: Double
        public let probability: Double?
        public var speaker: String?

        public init(word: String, start: Double, end: Double, probability: Double? = nil, speaker: String? = nil) {
            self.word = word
            self.start = start
            self.end = end
            self.probability = probability
            self.speaker = speaker
        }
    }

    public init(
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

    public var textForLLM: String {
        if segments.isEmpty {
            return text.replacingOccurrences(of: #"\*\*\[\d{2}:\d{2}:\d{2}\]\*\*"#, with: "", options: .regularExpression)
        }
        let hasSpeakerInfo = segments.contains { $0.speaker != nil }
        if hasSpeakerInfo {
            var lines: [String] = []
            var currentSpeaker: String? = nil
            var currentParts: [String] = []
            for segment in segments {
                let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if segment.speaker == currentSpeaker {
                    currentParts.append(trimmed)
                } else {
                    if !currentParts.isEmpty {
                        let joined = currentParts.joined(separator: " ")
                        lines.append(currentSpeaker.map { "\($0): \(joined)" } ?? joined)
                    }
                    currentSpeaker = segment.speaker
                    currentParts = [trimmed]
                }
            }
            if !currentParts.isEmpty {
                let joined = currentParts.joined(separator: " ")
                lines.append(currentSpeaker.map { "\($0): \(joined)" } ?? joined)
            }
            return lines.joined(separator: "\n")
        }
        return segments.map { $0.text }.joined(separator: " ")
    }
}
