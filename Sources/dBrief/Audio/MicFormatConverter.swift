import AVFoundation

/// Converts mic buffers from one `AVAudioFormat` to another on the real-time audio
/// thread. Used by live input-device hot-swap so a new device whose native format
/// differs from the in-progress track still writes into one continuous file.
///
/// `@unchecked Sendable`: MicCaptureSink serializes conversion and retirement
/// under its lock. LiveAudioConversion instead confines an instance to one stream
/// consumer. Callers must never convert and finish concurrently without that lock.
final class MicFormatConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private var hasInput = false
    private var isFinished = false

    init?(from sourceFormat: AVAudioFormat, to targetFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return nil }
        self.converter = converter
        self.targetFormat = targetFormat
    }

    /// Convert one input buffer to the target format. Returns nil on failure.
    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard !isFinished, input.frameLength > 0 else { return nil }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        let source = AudioConverterInput(input)
        hasInput = true
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            source.take(status: inputStatus)
        }

        if status == .error || conversionError != nil || output.frameLength == 0 {
            return nil
        }
        return output
    }

    /// End the source and recover both packet batching and the resampler's filter
    /// tail. Terminal and idempotent; pause/resume must keep using the open converter.
    func finish() throws -> [AVAudioPCMBuffer] {
        var buffers: [AVAudioPCMBuffer] = []
        try finish { buffers.append($0) }
        return buffers
    }

    /// Deliver batches as they are recovered, so a later converter failure cannot
    /// discard audio already available for the durable microphone track.
    func finish(consume: (AVAudioPCMBuffer) -> Void) throws {
        guard !isFinished else { return }
        isFinished = true
        guard hasInput else { return }
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else {
                throw AudioConversionError.cannotAllocate
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            guard status != .error else { throw AudioConversionError.conversionFailed }
            if output.frameLength > 0 { consume(output) }
            if status == .endOfStream { return }
            // With end-of-stream supplied, a nonterminal conversion must advance.
            guard output.frameLength > 0 else { throw AudioConversionError.conversionFailed }
        }
    }
}

enum AudioConversionError: Error {
    case cannotAllocate, conversionFailed, unsupportedFormat, alreadyFinished
}
