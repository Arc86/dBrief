import Foundation
import dBriefWire

/// Pure response→`TranscriptionResult` mappers for native cloud ASR providers.
/// Kept free of networking so they're unit-testable (mirrors `AppleSpeechResultMapper`).
enum CloudASRMappers {

    /// One decoded word before segment grouping.
    struct TimedWord {
        var text: String
        var start: Double
        var end: Double
        var probability: Double?
        var speaker: String?
    }

    /// Pause (seconds) between words that starts a new segment.
    static let segmentPauseThreshold = 1.0

    // MARK: - Deepgram (/v1/listen)

    /// Maps a Deepgram `results.channels[0].alternatives[0]` payload.
    static func parseDeepgram(_ data: Data, language: String?) -> TranscriptionResult {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let results = json?["results"] as? [String: Any]
        let channels = results?["channels"] as? [[String: Any]]
        let alt = (channels?.first?["alternatives"] as? [[String: Any]])?.first
        let transcript = (alt?["transcript"] as? String) ?? ""

        let rawWords = (alt?["words"] as? [[String: Any]]) ?? []
        let words: [TimedWord] = rawWords.compactMap { w in
            guard let start = w["start"] as? Double, let end = w["end"] as? Double else { return nil }
            let text = (w["punctuated_word"] as? String) ?? (w["word"] as? String) ?? ""
            let speaker = (w["speaker"] as? Int).map { "Speaker \($0 + 1)" }
            return TimedWord(text: text, start: start, end: end, probability: w["confidence"] as? Double, speaker: speaker)
        }

        let detectedLanguage = (results?["channels"] as? [[String: Any]])?.first?["detected_language"] as? String
        return build(fullText: transcript, words: words, language: detectedLanguage ?? language)
    }

    // MARK: - ElevenLabs (/v1/speech-to-text)

    /// Maps an ElevenLabs Scribe payload (`text` + `words[]`).
    static func parseElevenLabs(_ data: Data) -> TranscriptionResult {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let transcript = (json?["text"] as? String) ?? ""
        let language = json?["language_code"] as? String

        let rawWords = (json?["words"] as? [[String: Any]]) ?? []
        let words: [TimedWord] = rawWords.compactMap { w in
            // Skip "spacing"/"audio_event" entries — keep only spoken words.
            if let type = w["type"] as? String, type != "word" { return nil }
            guard let text = w["text"] as? String,
                  let start = w["start"] as? Double,
                  let end = w["end"] as? Double
            else { return nil }
            let speaker = (w["speaker_id"] as? String).map { normalizeSpeaker($0) }
            return TimedWord(text: text, start: start, end: end, probability: nil, speaker: speaker)
        }

        return build(fullText: transcript, words: words, language: language)
    }

    // MARK: - Shared

    /// Map "speaker_0" → "Speaker 1"; pass through anything else.
    static func normalizeSpeaker(_ id: String) -> String {
        if let n = Int(id.split(separator: "_").last.map(String.init) ?? "") {
            return "Speaker \(n + 1)"
        }
        return id
    }

    /// Group timed words into segments, splitting on speaker change or a long pause.
    /// Falls back to a single full-text segment when no word timings are present.
    static func build(fullText: String, words: [TimedWord], language: String?) -> TranscriptionResult {
        let trimmedText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            return TranscriptionResult(
                text: trimmedText,
                segments: trimmedText.isEmpty ? [] : [.init(start: 0, end: 0, text: trimmedText)],
                language: language
            )
        }

        let speakerCount = Set(words.compactMap(\.speaker)).count

        var segments: [TranscriptionResult.Segment] = []
        var bucket: [TimedWord] = []

        func flush() {
            guard let first = bucket.first, let last = bucket.last else { return }
            segments.append(
                TranscriptionResult.Segment(
                    start: first.start,
                    end: last.end,
                    text: bucket.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces),
                    words: bucket.map {
                        TranscriptionResult.Word(word: $0.text, start: $0.start, end: $0.end, probability: $0.probability, speaker: $0.speaker)
                    },
                    speaker: first.speaker
                )
            )
            bucket = []
        }

        for word in words {
            if let last = bucket.last {
                let gap = word.start - last.end
                if word.speaker != last.speaker || gap > segmentPauseThreshold {
                    flush()
                }
            }
            bucket.append(word)
        }
        flush()

        return TranscriptionResult(
            text: trimmedText.isEmpty ? segments.map(\.text).joined(separator: " ") : trimmedText,
            segments: segments,
            language: language,
            speakerCount: speakerCount > 0 ? speakerCount : nil
        )
    }
}
