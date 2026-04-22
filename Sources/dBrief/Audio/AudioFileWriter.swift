@preconcurrency import AVFoundation
import os

private let log = Logger.audio

enum AudioFileWriterError: Error, LocalizedError {
    case noCompatibleFLACEncoder

    var errorDescription: String? {
        switch self {
        case .noCompatibleFLACEncoder:
            return "No compatible FLAC audio encoder is available on this system."
        }
    }
}

final class AudioFileWriter: @unchecked Sendable {
    private let fileURL: URL
    private var audioFile: AVAudioFile?
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var _lastPeakLevel: Float = 0

    /// Thread-safe peak level from the last written buffer.
    var lastPeakLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return _lastPeakLevel
    }

    init(fileURL: URL) {
        // Normalise extension to .flac
        let outputURL = fileURL.pathExtension.lowercased() == "flac"
            ? fileURL
            : fileURL.deletingPathExtension().appendingPathExtension("flac")
        self.fileURL = outputURL
    }

    var actualFileURL: URL {
        audioFile?.url ?? fileURL
    }

    private var writeCount = 0

    func write(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }

        // Lazily create the AVAudioFile on the first write, using the buffer's own format.
        if audioFile == nil {
            let format = buffer.format
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVEncoderBitDepthHintKey: 16,
            ]
            do {
                let file = try AVAudioFile(
                    forWriting: fileURL,
                    settings: settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                audioFile = file
                log.info("[AudioFileWriter] Created FLAC file at \(self.fileURL.lastPathComponent, privacy: .public) — \(format.sampleRate, privacy: .public)Hz, \(format.channelCount, privacy: .public)ch, interleaved=\(format.isInterleaved, privacy: .public)")
            } catch {
                log.error("[AudioFileWriter] Failed to create FLAC file: \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        guard let audioFile else { return }

        // Compute peak level from raw input
        _lastPeakLevel = Self.extractPeakLevel(from: buffer)

        if writeCount == 0 {
            log.info("[AudioFileWriter] First buffer: \(buffer.format.sampleRate, privacy: .public)Hz, \(buffer.format.channelCount, privacy: .public)ch, interleaved=\(buffer.format.isInterleaved, privacy: .public), frames=\(buffer.frameLength, privacy: .public). Target: \(audioFile.processingFormat.sampleRate, privacy: .public)Hz, \(audioFile.processingFormat.channelCount, privacy: .public)ch")
        }

        if buffer.format != audioFile.processingFormat {
            guard let converted = convert(buffer, to: audioFile.processingFormat) else {
                if writeCount == 0 {
                    log.error("[AudioFileWriter] Conversion returned nil. Input: \(buffer.format.sampleRate, privacy: .public)Hz \(buffer.format.channelCount, privacy: .public)ch, target: \(audioFile.processingFormat.sampleRate, privacy: .public)Hz")
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
