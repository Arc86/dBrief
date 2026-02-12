@preconcurrency import AVFoundation
import os

private let log = Logger(subsystem: "com.dbrief.app", category: "audio")

enum AudioFileWriterError: Error, LocalizedError {
    case noCompatibleM4AEncoder

    var errorDescription: String? {
        switch self {
        case .noCompatibleM4AEncoder:
            return "No compatible M4A audio encoder is available on this system."
        }
    }
}

final class AudioFileWriter: @unchecked Sendable {
    private let fileURL: URL
    private var audioFile: AVAudioFile?
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private let processingFormat: AVAudioFormat
    private var _lastPeakLevel: Float = 0

    /// Thread-safe peak level from the last written buffer.
    var lastPeakLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return _lastPeakLevel
    }

    init(fileURL: URL, sampleRate: Int = 16000, bitRate: Int = 128000) throws {
        self.fileURL = fileURL

        let rate = Double(sampleRate)

        // Processing format: mono float32 at configured sample rate
        self.processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 1,
            interleaved: false
        )!

        let outputURL = fileURL.pathExtension.lowercased() == "m4a"
            ? fileURL
            : fileURL.deletingPathExtension().appendingPathExtension("m4a")

        // Keep output strictly in .m4a, trying AAC first, then Apple Lossless.
        let candidates: [(name: String, settings: [String: Any])] = [
            (
                "AAC",
                [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: bitRate,
                ]
            ),
            (
                "Apple Lossless",
                [
                    AVFormatIDKey: kAudioFormatAppleLossless,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 1,
                ]
            ),
        ]

        for candidate in candidates {
            do {
                self.audioFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: candidate.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                log.info("File writer: \(candidate.name, privacy: .public) in \(outputURL.lastPathComponent, privacy: .public)")
                return
            } catch {
                log.warning("\(candidate.name, privacy: .public) encoder not available (\(error.localizedDescription, privacy: .public))")
            }
        }

        throw AudioFileWriterError.noCompatibleM4AEncoder
    }

    var actualFileURL: URL {
        audioFile?.url ?? fileURL
    }

    private var writeCount = 0

    func write(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let audioFile else { return }

        // Compute peak level from raw input
        _lastPeakLevel = Self.extractPeakLevel(from: buffer)

        if buffer.format != processingFormat {
            guard let converted = convert(buffer, to: processingFormat) else {
                if writeCount == 0 {
                    log.error("Conversion returned nil. Input: \(buffer.format.sampleRate, privacy: .public)Hz \(buffer.format.channelCount, privacy: .public)ch, target: \(self.processingFormat.sampleRate, privacy: .public)Hz")
                }
                return
            }
            try audioFile.write(from: converted)
        } else {
            try audioFile.write(from: buffer)
        }

        writeCount += 1
        if writeCount == 1 {
            log.info("First audio buffer written (\(buffer.frameLength) frames)")
        }
    }

    private static func extractPeakLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        for i in 0..<frames {
            let sample = abs(channelData[0][i])
            if sample > peak { peak = sample }
        }
        return peak
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        audioFile = nil
        converter = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        nonisolated(unsafe) var provided = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if !provided {
                outStatus.pointee = .haveData
                provided = true
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        if let error {
            log.error("Conversion error: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        return outputBuffer
    }
}
