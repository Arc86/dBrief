import Foundation

/// Result of a TTSKit (Qwen3-TTS) synthesis run. The generated audio is written
/// to a file by the helper (audio is never sent over the pipe — same contract as
/// transcription), so this carries only the output path and lightweight metadata.
public struct SpeechSynthesisResult: Sendable, Codable {
    /// Filesystem path of the written audio (WAV, mono, `sampleRate` Hz).
    public let outputPath: String
    /// Duration of the synthesized audio in seconds.
    public let durationSeconds: Double
    /// Sample rate of the written audio in Hz.
    public let sampleRate: Int

    public init(outputPath: String, durationSeconds: Double, sampleRate: Int) {
        self.outputPath = outputPath
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
    }
}
