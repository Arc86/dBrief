import Foundation
import Testing
@testable import dBrief

@Suite("Live speech chunker")
struct LiveSpeechChunkerTests {
    private static let rate = 16_000

    private static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    private static func speech(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float(0.1 * sin(2 * Double.pi * 440 * Double($0) / Double(rate))) }
    }

    @Test func leadingSilenceIsDroppedAndUtteranceEndsAtLongPause() {
        var chunker = LiveSpeechChunker()
        let chunks = chunker.append(Self.silence(3) + Self.speech(1) + Self.silence(1.2))
        #expect(chunks.count == 1)
        // 0.25 s lead-in before speech onset at 3 s.
        #expect(chunks.first?.startSample == 44_000)
        // lead-in + 1 s speech + the 1 s end-of-utterance pause.
        #expect(chunks.first?.samples.count == 4_000 + 16_000 + 16_000)
        #expect(chunker.flush() == nil)
    }

    @Test func continuousSpeechIsForceCutAtMaxLength() {
        var chunker = LiveSpeechChunker(configuration: .forTarget(seconds: 2))
        let chunks = chunker.append(Self.speech(9))
        #expect(chunks.map(\.startSample) == [0, 64_000])
        #expect(chunks.allSatisfy { $0.samples.count == 64_000 })
        let tail = chunker.flush()
        #expect(tail?.startSample == 128_000)
        #expect(tail?.samples.count == 16_000)
    }

    @Test func shortPauseCutsOnceTargetLengthIsReached() {
        var chunker = LiveSpeechChunker(configuration: .forTarget(seconds: 2))
        let chunks = chunker.append(Self.speech(2.5) + Self.silence(0.4) + Self.speech(1) + Self.silence(1.2))
        #expect(chunks.count == 2)
        // 2.5 s speech + 0.35 s pause.
        #expect(chunks.first?.samples.count == 45_600)
        #expect(chunks.last?.startSample == 45_600)
    }

    @Test func shortPauseBeforeTargetDoesNotCut() {
        var chunker = LiveSpeechChunker(configuration: .forTarget(seconds: 6))
        let chunks = chunker.append(Self.speech(1) + Self.silence(0.5) + Self.speech(1))
        #expect(chunks.isEmpty)
        #expect(chunker.flush()?.startSample == 0)
    }

    @Test func noiseBlipAndPureSilenceNeverProduceChunks() {
        var chunker = LiveSpeechChunker()
        let chunks = chunker.append(Self.silence(1) + Self.speech(0.05) + Self.silence(2))
        #expect(chunks.isEmpty)
        #expect(chunker.flush() == nil)
    }

    @Test func pieceSizeDoesNotChangeTheCuts() {
        let audio = Self.silence(0.7) + Self.speech(2.5) + Self.silence(0.4) + Self.speech(3) + Self.silence(1.3) + Self.speech(0.6)
        var whole = LiveSpeechChunker(configuration: .forTarget(seconds: 2))
        var expected = whole.append(audio)
        expected += [whole.flush()].compactMap { $0 }

        var pieces = LiveSpeechChunker(configuration: .forTarget(seconds: 2))
        var actual: [LiveSpeechChunker.Chunk] = []
        var index = 0
        while index < audio.count {
            let end = min(index + 333, audio.count)
            actual += pieces.append(Array(audio[index..<end]))
            index = end
        }
        actual += [pieces.flush()].compactMap { $0 }
        #expect(actual == expected)
        #expect(expected.count >= 3)
    }
}
