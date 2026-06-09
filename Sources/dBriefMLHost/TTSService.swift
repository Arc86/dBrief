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

    init(stateHandler: @escaping @Sendable (LocalAIPluginState) -> Void) {
        self.stateHandler = stateHandler
    }

    // MARK: - Public API

    /// Synthesize `text` to a mono WAV at `outputPath`. Loads the model on first call.
    func synthesize(text: String, outputPath: String, voice: String?, language: String?) async throws -> SpeechSynthesisResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WireError(kind: .generic, message: "TTS: empty text")
        }
        let engine = try await loadTTS()
        let result: SpeechResult
        do {
            result = try await engine.generate(text: trimmed, voice: voice, language: language)
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
    }

    /// Delete the cached TTS model directory.
    func purgeModels() throws {
        let dir = try ttsDownloadBaseURL()
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    // MARK: - Loading

    private func loadTTS() async throws -> TTSKit {
        if let tts { return tts }
        let downloadBase = try ttsDownloadBaseURL()
        let config = TTSKitConfig(
            downloadBase: downloadBase,
            verbose: true,
            logLevel: .info
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
