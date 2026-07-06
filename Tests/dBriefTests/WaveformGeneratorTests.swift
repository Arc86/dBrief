import AVFoundation
import Foundation
import Testing
@testable import dBrief

@Suite("WaveformGenerator")
struct WaveformGeneratorTests {

    /// Writes a mono 16 kHz WAV whose samples are produced by `sample(frameIndex)`.
    private func makeWAV(frames: Int, sample: (Int) -> Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("waveform-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData![0]
        for i in 0..<frames { data[i] = sample(i) }
        try file.write(from: buffer)
        return url
    }

    /// Reference implementation: the original whole-file-in-RAM algorithm.
    /// The streaming version must produce the same buckets.
    private func oracle(from url: URL, sampleCount: Int) -> [Float] {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return [] }
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount),
              (try? audioFile.read(into: buffer)) != nil,
              let channelData = buffer.floatChannelData?[0]
        else { return [] }

        let totalFrames = Int(buffer.frameLength)
        let framesPerBucket = max(1, totalFrames / sampleCount)
        var result: [Float] = []
        var i = 0
        while i < totalFrames && result.count < sampleCount {
            let end = min(i + framesPerBucket, totalFrames)
            var peak: Float = 0
            for j in i..<end {
                let abs = channelData[j] < 0 ? -channelData[j] : channelData[j]
                if abs > peak { peak = abs }
            }
            result.append(peak)
            i = end
        }
        let maxVal = result.max() ?? 1
        guard maxVal > 0 else { return result }
        return result.map { $0 / maxVal }
    }

    @Test("matches the whole-file oracle on a structured signal")
    func matchesOracle() async throws {
        // ~13.1 s at 16 kHz — long enough that buckets span multiple read blocks
        // unevenly; envelope ramps so every bucket has a distinct peak.
        let frames = 210_000
        let url = try makeWAV(frames: frames) { i in
            let envelope = Float(i) / Float(frames)
            return envelope * (i % 2 == 0 ? 1 : -1)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = oracle(from: url, sampleCount: 800)
        let actual = await WaveformGenerator.generate(from: url, sampleCount: 800)
        try #require(actual.count == expected.count)
        for (a, e) in zip(actual, expected) {
            #expect(abs(a - e) < 1e-5)
        }
    }

    @Test("silence yields all-zero buckets without normalization blowup")
    func silence() async throws {
        let url = try makeWAV(frames: 32_000) { _ in 0 }
        defer { try? FileManager.default.removeItem(at: url) }
        let out = await WaveformGenerator.generate(from: url, sampleCount: 100)
        #expect(!out.isEmpty)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test("short file (fewer frames than buckets) still returns per-frame peaks")
    func shortFile() async throws {
        let url = try makeWAV(frames: 10) { i in Float(i + 1) / 10 }
        defer { try? FileManager.default.removeItem(at: url) }
        let out = await WaveformGenerator.generate(from: url, sampleCount: 800)
        #expect(out.count == 10)
        #expect(abs((out.last ?? 0) - 1.0) < 1e-5)   // normalized peak
    }
}
