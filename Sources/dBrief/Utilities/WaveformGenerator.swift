import Accelerate
import AVFoundation
import Foundation

enum WaveformGenerator {
    /// Asynchronously extracts a downsampled waveform amplitude array from an audio file.
    /// Returns ~`sampleCount` normalized values in 0…1. Empty on failure.
    static func generate(from url: URL, sampleCount: Int = 800) async -> [Float] {
        await Task.detached(priority: .utility) {
            generateSync(from: url, sampleCount: sampleCount)
        }.value
    }

    /// Frames decoded per read. Streaming in fixed blocks keeps memory O(block)
    /// instead of O(file) — the previous whole-file read held ~650 MB of decoded
    /// PCM for a 30-minute recording just to draw ~800 bars.
    private static let blockFrames: AVAudioFrameCount = 65_536

    private static func generateSync(from url: URL, sampleCount: Int) -> [Float] {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return [] }
        let totalFrames = Int(audioFile.length)
        guard totalFrames > 0, sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: blockFrames)
        else { return [] }

        let framesPerBucket = max(1, totalFrames / sampleCount)
        var result: [Float] = []
        result.reserveCapacity(sampleCount)

        var bucketPeak: Float = 0
        var framesInBucket = 0
        var framesRead = 0

        while framesRead < totalFrames && result.count < sampleCount {
            buffer.frameLength = 0
            guard (try? audioFile.read(into: buffer, frameCount: blockFrames)) != nil,
                  buffer.frameLength > 0,
                  let channelData = buffer.floatChannelData?[0]
            else { break }

            let n = Int(buffer.frameLength)
            var offset = 0
            while offset < n && result.count < sampleCount {
                let take = min(framesPerBucket - framesInBucket, n - offset)
                var blockPeak: Float = 0
                vDSP_maxmgv(channelData + offset, 1, &blockPeak, vDSP_Length(take))
                bucketPeak = max(bucketPeak, blockPeak)
                framesInBucket += take
                offset += take
                if framesInBucket == framesPerBucket {
                    result.append(bucketPeak)
                    bucketPeak = 0
                    framesInBucket = 0
                }
            }
            framesRead += n
        }
        // Partial final bucket (file length not a multiple of the bucket size).
        if framesInBucket > 0 && result.count < sampleCount {
            result.append(bucketPeak)
        }

        let maxVal = result.max() ?? 1
        guard maxVal > 0 else { return result }
        return result.map { $0 / maxVal }
    }
}
