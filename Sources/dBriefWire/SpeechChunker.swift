import Foundation

/// Splits text into short, sentence-aligned chunks for text-to-speech.
///
/// Neural TTS (Qwen3-TTS) loses energy and prosody toward the end of a long
/// single utterance — the tail drifts to a whisper / "talking while inhaling".
/// Synthesizing in short chunks and concatenating keeps every chunk inside the
/// model's stable range. Pure (no IO), unit-tested.
public enum SpeechChunker {
    /// Sentence-aware chunks no longer than `maxChars`. Sentences are packed
    /// greedily; a single sentence longer than `maxChars` is hard-split on word
    /// boundaries so no chunk ever exceeds the limit.
    public static func chunks(_ text: String, maxChars: Int = 240) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var chunks: [String] = []
        var current = ""
        for sentence in splitSentences(trimmed) {
            let units = sentence.count > maxChars ? hardSplit(sentence, maxChars: maxChars) : [sentence]
            for unit in units {
                if current.isEmpty {
                    current = unit
                } else if current.count + 1 + unit.count <= maxChars {
                    current += " " + unit
                } else {
                    chunks.append(current)
                    current = unit
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Split into sentences on `.`/`!`/`?` boundaries (and paragraph breaks),
    /// keeping the terminating punctuation. Abbreviation false-positives are
    /// harmless — greedy packing re-merges tiny fragments.
    private static func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            let chars = Array(paragraph)
            var sentence = ""
            var i = 0
            while i < chars.count {
                let c = chars[i]
                sentence.append(c)
                if c == "." || c == "!" || c == "?" {
                    let next: Character = i + 1 < chars.count ? chars[i + 1] : " "
                    if next == " " || next == "\t" {
                        let s = sentence.trimmingCharacters(in: .whitespaces)
                        if !s.isEmpty { result.append(s) }
                        sentence = ""
                    }
                }
                i += 1
            }
            let tail = sentence.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { result.append(tail) }
        }
        return result
    }

    /// Pack words into pieces no longer than `maxChars` (last resort for a
    /// sentence with no usable punctuation).
    private static func hardSplit(_ s: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for word in s.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= maxChars {
                current += " " + word
            } else {
                pieces.append(current)
                current = word
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
