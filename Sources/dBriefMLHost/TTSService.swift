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

        // Synthesize in short, sentence-aligned chunks and concatenate. A long
        // single utterance makes Qwen3-TTS lose energy toward the end (the tail
        // drifts to a whisper); per-chunk synthesis keeps prosody stable.
        let chunks = SpeechChunker.chunks(trimmed)
        var samples: [Float] = []
        var sampleRate = 0
        do {
            for (i, chunk) in chunks.enumerated() {
                let r = try await engine.generate(text: chunk, voice: voice, language: language)
                if sampleRate == 0 { sampleRate = r.sampleRate }
                // Brief silence between chunks for natural pacing.
                if i > 0, sampleRate > 0 {
                    samples.append(contentsOf: [Float](repeating: 0, count: Int(Double(sampleRate) * 0.18)))
                }
                samples.append(contentsOf: r.audio)
            }
        } catch {
            Logger.localAI.error("TTS generation failed: \(error.localizedDescription, privacy: .public)")
            throw WireError(kind: .generic, message: "TTS generation failed: \(error.localizedDescription)")
        }

        guard sampleRate > 0, !samples.isEmpty else {
            throw WireError(kind: .generic, message: "TTS: no audio produced")
        }

        let url = URL(fileURLWithPath: outputPath)
        do {
            try Self.writeWAV(samples: samples, sampleRate: sampleRate, to: url)
        } catch {
            throw WireError(kind: .generic, message: "TTS: writing audio failed: \(error.localizedDescription)")
        }
        return SpeechSynthesisResult(
            outputPath: url.path,
            durationSeconds: Double(samples.count) / Double(sampleRate),
            sampleRate: sampleRate
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
