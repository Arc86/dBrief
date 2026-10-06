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
    public static let maxTurnSeconds: Double = 60

    /// Maps speaker label IDs to display names. Duplicates prefer the first; empty names fall back to ID.
    public static func speakerNames(_ labels: [(id: String, displayName: String)]) -> [String: String] {
        Dictionary(labels.map {
            let name = $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return ($0.id, name.isEmpty ? $0.id : name)
        }, uniquingKeysWith: { first, _ in first })
    }

    public static func turns(_ segments: [(start: Double, end: Double, speaker: String?, text: String)]) -> [TranscriptTurn] {
        var out: [TranscriptTurn] = []
        for s in segments {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = out.last, last.speaker == s.speaker, s.end - last.start <= maxTurnSeconds {
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
        guard seconds.isFinite else { return "00:00:00" }
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
