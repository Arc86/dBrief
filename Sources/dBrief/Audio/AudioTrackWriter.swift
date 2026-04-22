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

    func write(_ buffer: AVAudioPCMBuffer) throws {
        try lock.withLock {
            if audioFile == nil {
                let format = buffer.format
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: Int(format.channelCount),
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: !format.isInterleaved,
                ]
                do {
                    audioFile = try AVAudioFile(
                        forWriting: url,
                        settings: settings,
                        commonFormat: .pcmFormatFloat32,
                        interleaved: false
                    )
                    log.info("[AudioTrackWriter:\(self.role.rawValue, privacy: .public)] opened \(self.url.lastPathComponent, privacy: .public) @ \(format.sampleRate, privacy: .public)Hz \(format.channelCount, privacy: .public)ch")
                } catch {
                    log.error("[AudioTrackWriter:\(self.role.rawValue, privacy: .public)] failed to open: \(error.localizedDescription, privacy: .public)")
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
