import AVFoundation

/// Confined to one live channel's stream consumer. Retires a previous format
/// before emitting the next format, and drains normal EOF before analyzer EOF.
final class LiveAudioConversion {
    private let targetFormat: AVAudioFormat
    private var sourceFormat: AVAudioFormat?
    private var converter: MicFormatConverter?
    private var isFinished = false

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
        guard !isFinished else { throw AudioConversionError.alreadyFinished }
        var output: [AVAudioPCMBuffer] = []
        if sourceFormat != buffer.format {
            output = try converter?.finish() ?? []
            converter = nil
            sourceFormat = nil
            guard let next = MicFormatConverter(from: buffer.format, to: targetFormat) else {
                throw AudioConversionError.unsupportedFormat
            }
            converter = next
            sourceFormat = buffer.format
        }
        if let converted = converter?.convert(buffer) { output.append(converted) }
        return output
    }

    func finish() throws -> [AVAudioPCMBuffer] {
        guard !isFinished else { return [] }
        isFinished = true
        return try converter?.finish() ?? []
    }

    /// Strict source consumers cut on format changes instead of concatenating a
    /// retired converter's tail with an unrelated input epoch.
    func convertChecked(_ buffer: AVAudioPCMBuffer, maximumOutputFrames: Int) throws -> AVAudioPCMBuffer? {
        guard !isFinished else { throw AudioConversionError.alreadyFinished }
        guard sourceFormat == nil || sourceFormat == buffer.format else { throw AudioConversionError.unsupportedFormat }
        if converter == nil {
            guard let next = MicFormatConverter(from: buffer.format,to: targetFormat) else {
                throw AudioConversionError.unsupportedFormat
            }
            converter = next; sourceFormat = buffer.format
        }
        return try converter?.convertChecked(buffer,maximumOutputFrames: maximumOutputFrames)
    }

    func finishBounded(maximumOutputFrames: Int) throws -> [AVAudioPCMBuffer] {
        guard !isFinished else { return [] }
        isFinished = true
        var output: [AVAudioPCMBuffer] = [], count = 0
        try converter?.finish { buffer in
            guard Int(buffer.frameLength) <= maximumOutputFrames - count else { throw AudioConversionError.outputLimit }
            count += Int(buffer.frameLength); output.append(buffer)
        }
        return output
    }
}
