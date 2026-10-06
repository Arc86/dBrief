import Foundation

/// Cuts a live 16 kHz mono sample stream into speech chunks for batch ASR
/// (live Parakeet). Pure and synchronous so the cut rules are unit-testable.
///
/// A chunk is cut at a natural pause once it reaches `targetSeconds`, after a
/// long end-of-utterance pause regardless of length, or unconditionally at
/// `maxSeconds`. Silence before any speech is dropped (keeping a short
/// lead-in), and chunks without enough speech are never emitted, so the ASR
/// model never sees pure silence (the usual hallucination trigger).
struct LiveSpeechChunker: Sendable {
    struct Configuration: Sendable, Equatable {
        var sampleRate = 16_000
        /// Preferred chunk length — the main latency/accuracy knob.
        var targetSeconds = 6.0
        /// Hard cap, cut even mid-speech.
        var maxSeconds = 12.0
        /// A pause this long ends a chunk once it reaches `targetSeconds`.
        var pauseSeconds = 0.35
        /// A pause this long ends a chunk at any length (end of utterance).
        var endOfUtteranceSeconds = 1.0
        /// Chunks with less voiced audio than this are discarded.
        var minSpeechSeconds = 0.25
        /// Silence kept before the first voiced frame of a chunk.
        var leadInSeconds = 0.25
        /// Frame RMS at or above this counts as speech (~-44 dBFS).
        var speechRMS: Float = 0.006
        /// Analysis frame size (50 ms at 16 kHz).
        var frameSamples = 800

        static func forTarget(seconds: Double) -> Self {
            var config = Self()
            config.targetSeconds = max(2, seconds)
            config.maxSeconds = config.targetSeconds * 2
            return config
        }
    }

    struct Chunk: Sendable, Equatable {
        /// Index of the first sample in the channel's stream.
        let startSample: Int
        let samples: [Float]
    }

    let configuration: Configuration
    private var pending: [Float] = []
    /// Absolute stream index of `pending[0]`.
    private var pendingStart = 0
    /// Samples of `pending` already classified (always whole frames).
    private var analyzed = 0
    private var speechFrames = 0
    private var trailingSilentFrames = 0

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Feeds samples and returns any chunks completed by them.
    mutating func append(_ samples: [Float]) -> [Chunk] {
        pending.append(contentsOf: samples)
        let config = configuration, frame = config.frameSamples
        let rate = Double(config.sampleRate)
        let leadInSamples = Int(config.leadInSeconds * rate) / frame * frame
        var chunks: [Chunk] = []
        while pending.count - analyzed >= frame {
            let voiced = Self.rms(pending[analyzed..<(analyzed + frame)]) >= config.speechRMS
            analyzed += frame
            if voiced {
                speechFrames += 1
                trailingSilentFrames = 0
            } else {
                trailingSilentFrames += 1
            }
            if speechFrames == 0 {
                if analyzed > leadInSamples { dropPrefix(analyzed - leadInSamples) }
                continue
            }
            let length = Double(analyzed) / rate
            let pause = Double(trailingSilentFrames * frame) / rate
            if (length >= config.targetSeconds && pause >= config.pauseSeconds)
                || pause >= config.endOfUtteranceSeconds
                || length >= config.maxSeconds {
                if let chunk = cut() { chunks.append(chunk) }
            }
        }
        return chunks
    }

    /// Returns the buffered remainder as a final chunk (end of stream).
    mutating func flush() -> Chunk? {
        analyzed = pending.count
        return cut()
    }

    private mutating func cut() -> Chunk? {
        let voicedSeconds = Double(speechFrames * configuration.frameSamples) / Double(configuration.sampleRate)
        let chunk = Chunk(startSample: pendingStart, samples: Array(pending[0..<analyzed]))
        dropPrefix(analyzed)
        speechFrames = 0
        trailingSilentFrames = 0
        return voicedSeconds >= configuration.minSpeechSeconds ? chunk : nil
    }

    private mutating func dropPrefix(_ count: Int) {
        pending.removeFirst(count)
        pendingStart += count
        analyzed -= count
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
