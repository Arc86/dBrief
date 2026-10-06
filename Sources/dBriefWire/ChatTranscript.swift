import Foundation

public struct TranscriptTurn: Sendable, Equatable, Codable {
    public let start: Double
    public let end: Double
    public let speaker: String?
    public let text: String
    public init(start: Double, end: Double, speaker: String?, text: String) {
        self.start = start; self.end = end; self.speaker = speaker; self.text = text
    }
}

/// Speaker-attributed, timestamped transcript text for chat prompts and retrieval.
public enum ChatTranscript {
    public static func turns(_ segments: [(start: Double, end: Double, speaker: String?, text: String)]) -> [TranscriptTurn] {
        var out: [TranscriptTurn] = []
        for s in segments {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = out.last, last.speaker == s.speaker {
                out[out.count - 1] = TranscriptTurn(start: last.start, end: s.end, speaker: last.speaker,
                                                    text: last.text + " " + text)
            } else {
                out.append(TranscriptTurn(start: s.start, end: s.end, speaker: s.speaker, text: text))
            }
        }
        return out
    }

    public static func format(_ turns: [TranscriptTurn]) -> String {
        turns.map { turn in
            let name = turn.speaker.map { "\($0): " } ?? ""
            return "[\(timestamp(turn.start))] \(name)\(turn.text)"
        }.joined(separator: "\n")
    }

    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
