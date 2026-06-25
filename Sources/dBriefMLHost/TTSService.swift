import Foundation
import dBriefWire
import TTSKit
import AVFoundation
import OSLog

/// Crash-isolated wrapper around TTSKit (Qwen3-TTS) text-to-speech.
///
/// This is a minimal scaffold: it loads the model lazily on first synthesis,
/// writes the generated mono PCM to a WAV file (audio is passed by path, never
/// over the pipe — same contract as the transcription services), and unloads on
/// memory pressure / force-unload via `MLOrchestrator`. No UI surfaces it yet.
final class TTSService: @unchecked Sendable {
    private let stateHandler: @Sendable (LocalAIPluginState) -> Void
    private var tts: TTSKit?
    /// Variant of the currently-loaded `tts`, so a model-size change reloads.
    private var loadedVariant: TTSModelVariant?

    init(stateHandler: @escaping @Sendable (LocalAIPluginState) -> Void) {
        self.stateHandler = stateHandler
    }

    // MARK: - Public API

    /// Synthesize `text` to a mono WAV at `outputPath`. Loads the model on first
    /// call. `instruction` is a calm-delivery style hint (1.7B only; the 0.6B
    /// variant ignores it). `model` is a `TTSModelSize` raw value ("0.6b"/"1.7b").
    func synthesize(text: String, outputPath: String, voice: String?, language: String?, instruction: String?, model: String?) async throws -> SpeechSynthesisResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WireError(kind: .generic, message: "TTS: empty text")
        }
        let variant = Self.variant(for: model)
        let engine = try await loadTTS(variant: variant)
        let styleInstruction = instruction?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedInstruction = (styleInstruction?.isEmpty ?? true) ? nil : styleInstruction

        // Let TTSKit handle long text: its `generate` splits on sentence
        // boundaries (default `.sentence` strategy) and crossfades the chunks by
        // 100 ms internally, keeping prosody stable and joins seamless — far
        // better than hand-concatenating per-chunk WAVs (which clicks and varies
        // in level). The 1.7B model sounds markedly more natural than 0.6B and is
        // the only one that follows `instruction` (see GenerationOptions).
        let result: SpeechResult
        do {
            result = try await engine.generate(
                text: trimmed,
                voice: voice,
                language: language,
                options: GenerationOptions(instruction: resolvedInstruction)
            )
        } catch {
            Logger.localAI.error("TTS generation failed: \(error.localizedDescription, privacy: .public)")
            throw WireError(kind: .generic, message: "TTS generation failed: \(error.localizedDescription)")
        }

        let url = URL(fileURLWithPath: outputPath)
        do {
            try Self.writeWAV(samples: result.audio, sampleRate: result.sampleRate, to: url)
        } catch {
            throw WireError(kind: .generic, message: "TTS: writing audio failed: \(error.localizedDescription)")
        }
        return SpeechSynthesisResult(
            outputPath: url.path,
            durationSeconds: result.audioDuration,
            sampleRate: result.sampleRate
        )
    }

    func unload() async {
        await tts?.unloadModels()
        tts = nil
        loadedVariant = nil
    }

    /// Delete the cached TTS model directory.
    func purgeModels() throws {
        let dir = try ttsDownloadBaseURL()
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    // MARK: - Loading

    /// Maps a `TTSModelSize` raw value to a TTSKit variant, defaulting to the
    /// more natural 1.7B when unset/unknown (macOS-only, which this app always is).
    private static func variant(for model: String?) -> TTSModelVariant {
        guard let model, let v = TTSModelVariant(rawValue: model) else { return .qwen3TTS_1_7b }
        return v
    }

    private func loadTTS(variant: TTSModelVariant) async throws -> TTSKit {
        // Reuse a loaded engine only if it matches the requested variant; otherwise
        // unload and reload so a settings change takes effect. (In practice the
        // orchestrator unloads after every synth, so this is belt-and-suspenders.)
        if let tts, loadedVariant == variant { return tts }
        if tts != nil { await unload() }
        let downloadBase = try ttsDownloadBaseURL()
        // `load: false` so the initializer does NOT auto-load after it resolves
        // the model folder — otherwise the model loads twice (init + our explicit
        // loadModels below), and the first generate can race a still-loading
        // component ("MultiCodeEmbedder model not loaded"). We load exactly once,
        // after attaching the progress callback. The race is wider on the heavier
        // 1.7B model, which is why it surfaced there.
        let config = TTSKitConfig(
            model: variant,
            downloadBase: downloadBase,
            verbose: true,
            logLevel: .info,
            load: false
        )
        let engine = try await TTSKit(config)
        engine.modelStateCallback = { [stateHandler] (_, newState: ModelState) in
            switch newState {
            case .downloading:
                stateHandler(.downloading(progress: nil, stage: .ttsModel))
            case .loading, .prewarming:
                stateHandler(.downloading(progress: nil, stage: .ttsModelLoading))
            default:
                break
            }
        }
        try await engine.loadModels()
        self.tts = engine
        self.loadedVariant = variant
        return engine
    }

    // MARK: - Paths

    private let fileManager = FileManager.default

    private func ttsDownloadBaseURL() throws -> URL {
        try SupportPaths.subdirectory("TTS")
    }

    // MARK: - WAV writing

    /// Write mono Float32 PCM `samples` to a 16-bit PCM WAV at `url`.
    private static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw WireError(kind: .generic, message: "TTS: invalid audio format")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(max(samples.count, 1))
        ) else {
            throw WireError(kind: .generic, message: "TTS: could not allocate audio buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buffer)
    }
}
