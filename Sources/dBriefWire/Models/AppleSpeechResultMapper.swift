import Foundation

/// A single timed run (≈ a word) extracted from a `SpeechTranscriber` result's
/// attributed text. Plain values so the mapping logic is testable without macOS 26.
public struct AppleSpeechRun: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// One finalized `SpeechTranscriber` result chunk: its overall text/time range plus
/// the per-run (word-level) timings read from the `audioTimeRange` attribute.
public struct AppleSpeechChunk: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double
    public let runs: [AppleSpeechRun]

    public init(text: String, start: Double, end: Double, runs: [AppleSpeechRun]) {
        self.text = text
        self.start = start
        self.end = end
        self.runs = runs
    }
}

/// Pure, OS-independent mapping from SpeechAnalyzer chunks to a `TranscriptionResult`.
/// Kept separate from the macOS 26-only service so it can be unit-tested directly.
public enum AppleSpeechResultMapper {
    public static func map(_ chunks: [AppleSpeechChunk], language: String?) -> TranscriptionResult {
        var segments: [TranscriptionResult.Segment] = []
        for chunk in chunks {
            let segText = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segText.isEmpty else { continue }

            let words: [TranscriptionResult.Word] = chunk.runs.compactMap { run in
                let trimmed = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return TranscriptionResult.Word(word: trimmed, start: run.start, end: run.end)
            }

            segments.append(
                TranscriptionResult.Segment(
                    start: chunk.start,
                    end: chunk.end,
                    text: segText,
                    words: words.isEmpty ? nil : words
                )
            )
        }

        let fullText = segments.map(\.text).joined(separator: " ")
        return TranscriptionResult(
            text: fullText,
            segments: segments,
            language: language?.isEmpty == false ? language : nil
        )
    }
}
