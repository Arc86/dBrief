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

/// Selectable Qwen3-TTS model size for spoken-summary synthesis. Raw values match
/// TTSKit's `TTSModelVariant` raw values so the helper can map them directly
/// without `dBrief` importing TTSKit.
public enum TTSModelSize: String, Codable, Sendable, CaseIterable {
    /// Lighter, faster; ignores the voice-style instruction. Better on 16 GB Macs.
    case small = "0.6b"
    /// Heavier; markedly more natural prosody and the only variant that follows
    /// the voice-style instruction.
    case large = "1.7b"

    /// Human-readable label for settings UI.
    public var displayName: String {
        switch self {
        case .small: "Qwen3 TTS 0.6B (lighter)"
        case .large: "Qwen3 TTS 1.7B (most natural)"
        }
    }

    /// Whether this variant follows the spoken-voice style instruction.
    public var supportsVoiceInstruction: Bool { self == .large }
}
