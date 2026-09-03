import AVFoundation
import Foundation

/// Chooses between WhisperKit's low-overhead full-buffer path and its
/// bounded-memory incremental file loader.
enum WhisperAudioLoadingPolicy {
    /// At 16 kHz mono, ten minutes is roughly 38 MB of raw Float audio before
    /// any temporary conversion buffers. Recording segments are normally 30
    /// minutes, so they benefit from streaming without changing short-clip
    /// behavior.
    static let incrementalThresholdSeconds: TimeInterval = 10 * 60

    static func shouldLoadIncrementally(
        durationSeconds: TimeInterval?,
        diarizationEnabled: Bool
    ) -> Bool {
        guard !diarizationEnabled,
              let durationSeconds,
              durationSeconds.isFinite
        else { return false }

        return durationSeconds >= incrementalThresholdSeconds
    }

    /// Reads only container metadata; it does not decode the audio payload.
    static func durationSeconds(for fileURL: URL) -> TimeInterval? {
        guard let audioFile = try? AVAudioFile(forReading: fileURL) else { return nil }
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0, audioFile.length >= 0 else { return nil }
        return Double(audioFile.length) / sampleRate
    }
}
