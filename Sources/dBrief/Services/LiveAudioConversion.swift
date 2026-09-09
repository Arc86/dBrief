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
}
