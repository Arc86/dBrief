import AVFoundation
import Foundation

enum AudioLevelMeter {
    /// Display-only scale: -60 dBFS (quiet floor) through 0 dBFS (full scale).
    /// Recorded samples remain unchanged. Linear amplitudes make ordinary speech
    /// look almost silent even when the microphone is capturing it correctly.
    static func displayLevel(_ peak: Float) -> Float {
        guard peak.isFinite, peak > 0 else { return 0 }
        let decibels = 20 * log10(peak)
        return min(1, max(0, (decibels + 60) / 60))
    }

    /// Capture uses float PCM. Include every channel, including interleaved stereo
    /// where floatChannelData contains one pointer to the interleaved samples.
    static func peak(in buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let planes = buffer.format.isInterleaved ? 1 : channels
        let samplesPerPlane = buffer.format.isInterleaved ? frames * channels : frames
        var peak: Float = 0
        for plane in 0..<planes {
            for frame in 0..<samplesPerPlane {
                let sample = abs(data[plane][frame])
                if sample.isFinite { peak = max(peak, sample) }
            }
        }
        return peak
    }
}
