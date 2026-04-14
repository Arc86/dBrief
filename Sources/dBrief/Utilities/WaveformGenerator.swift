import Foundation
import AVFoundation

enum WaveformGenerator {
    /// Asynchronously extracts a downsampled waveform amplitude array from an audio file.
    /// Returns ~`sampleCount` normalized values in 0…1. Empty on failure.
    static func generate(from url: URL, sampleCount: Int = 800) async -> [Float] {
        await Task.detached(priority: .utility) {
            generateSync(from: url, sampleCount: sampleCount)
        }.value
    }

    private static func generateSync(from url: URL, sampleCount: Int) -> [Float] {
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
        result.reserveCapacity(sampleCount)

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
}
