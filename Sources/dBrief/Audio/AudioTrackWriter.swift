@preconcurrency import AVFoundation
import os

private let log = Logger.audio

/// A single captured track on disk. Both URLs may be nil if the corresponding
/// source was not captured (no screen-recording permission → system=nil; no
/// mic permission → mic=nil). At least one is guaranteed non-nil by
/// `AudioCaptureManager` before `startRecording` returns.
struct CapturedTracks: Sendable {
    var systemURL: URL?
    var micURL: URL?
}

final class AudioTrackWriter: @unchecked Sendable {
    enum Role: String, Sendable { case system, mic }

    let url: URL
    let role: Role

    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var _peakLevel: Float = 0
    private var droppedCount = 0

    init(url: URL, role: Role) {
        self.url = url
        self.role = role
    }

    var peakLevel: Float {
        lock.withLock { _peakLevel }
    }

    /// The format the on-disk file was opened with (nil until the first buffer is
    /// written). Used by live device hot-swap to convert a new device's buffers back
    /// to this format so a single continuous track stays valid.
    var establishedFormat: AVAudioFormat? {
        lock.withLock { audioFile?.processingFormat }
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        try lock.withLock {
            if audioFile == nil {
                let format = buffer.format
                // Capture losslessly compressed (Apple Lossless) instead of raw
                // 16-bit LPCM. ALAC is bit-exact, so the finalized AAC master is
                // identical to what raw PCM would have produced, but the on-disk
                // per-track files are ~2x smaller during recording. ffmpeg decodes
                // ALAC transparently at finalization, so the sidechain DSP is
                // unaffected. We must use the settings-only initializer here — the
                // commonFormat:/interleaved: variant is LPCM-only; for a compressed
                // file AVAudioFile derives a float32 processingFormat that accepts
                // these buffers via write(from:).
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatAppleLossless,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: Int(format.channelCount),
                    AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
                ]
                do {
                    audioFile = try AVAudioFile(forWriting: url, settings: settings)
                    log.info("[AudioTrackWriter:\(self.role.rawValue, privacy: .public)] opened @ \(format.sampleRate, privacy: .public)Hz \(format.channelCount, privacy: .public)ch")
                } catch {
                    log.error("[AudioTrackWriter:\(self.role.rawValue, privacy: .public)] failed to open an audio track")
                    throw error
                }
            }

            // audioFile is guaranteed non-nil here (init threw if it failed, which re-throws)
            let file = audioFile!

            if buffer.format.sampleRate != file.processingFormat.sampleRate
                || buffer.format.channelCount != file.processingFormat.channelCount
            {
                droppedCount += 1
                if droppedCount == 1 {
                    log.error("[AudioTrackWriter:\(self.role.rawValue, privacy: .public)] format mismatch — dropping buffer. Got \(buffer.format.sampleRate, privacy: .public)Hz \(buffer.format.channelCount, privacy: .public)ch, file is \(file.processingFormat.sampleRate, privacy: .public)Hz \(file.processingFormat.channelCount, privacy: .public)ch")
                }
                return
            }

            _peakLevel = Self.peakLevel(of: buffer)
            try file.write(from: buffer)
        }
    }

    func close() {
        lock.withLock { audioFile = nil }
    }

    private static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        for i in 0..<frames {
            let sample = abs(channelData[0][i])
            if sample > peak { peak = sample }
        }
        return peak
    }
}
