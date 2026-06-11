@preconcurrency import AVFoundation
import os

/// Converts mic buffers from one `AVAudioFormat` to another on the real-time audio
/// thread. Used by live input-device hot-swap so a new device whose native format
/// differs from the in-progress track still writes into one continuous file.
///
/// `@unchecked Sendable`: the underlying `AVAudioConverter` is used only from the
/// single audio tap thread that owns this instance (one converter per tap install).
final class MicFormatConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat

    init?(from sourceFormat: AVAudioFormat, to targetFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return nil }
        self.converter = converter
        self.targetFormat = targetFormat
    }

    /// Convert one input buffer to the target format. Returns nil on failure.
    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }

        if status == .error || output.frameLength == 0 {
            return nil
        }
        return output
    }
}
