import Foundation

struct RichTranscript: Codable, Sendable {
    var segments: [Segment]
    var version: Int = 1

    struct Segment: Codable, Sendable, Identifiable {
        let id: UUID
        var start: Double
        var end: Double
        var text: String
        var wordTimings: [Word]?
        var isStarred: Bool
        var editedText: String?

        var displayText: String {
            editedText ?? text
        }

        init(
            id: UUID = UUID(),
            start: Double,
            end: Double,
            text: String,
            wordTimings: [Word]? = nil,
            isStarred: Bool = false,
            editedText: String? = nil
        ) {
            self.id = id
            self.start = start
            self.end = end
            self.text = text
            self.wordTimings = wordTimings
            self.isStarred = isStarred
            self.editedText = editedText
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

    init(segments: [Segment] = []) {
        self.segments = segments
    }

    init(from transcriptionResult: TranscriptionResult) {
        self.segments = transcriptionResult.segments.map { seg in
            let wordTimings: [RichTranscript.Word]? = seg.words?.map {
                RichTranscript.Word(word: $0.word, start: $0.start, end: $0.end, probability: $0.probability)
            }
            return Segment(
                start: seg.start,
                end: seg.end,
                text: seg.text,
                wordTimings: wordTimings,
                isStarred: false,
                editedText: nil
            )
        }
        self.version = 1
    }
}
