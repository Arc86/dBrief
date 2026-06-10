import Foundation
import AppKit
import dBriefWire

/// Resolves the helper binary and the shared model-cache base.
enum MLHostLocator {
    /// `Contents/MacOS/dBriefMLHost` next to the running app; falls back to the
    /// SwiftPM build dir when running unbundled (e.g. `swift run`).
    static func binaryURL() -> URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/dBriefMLHost")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return Bundle.main.bundleURL.appendingPathComponent("dBriefMLHost")
    }

    /// Use the app's real bundle id literally so the path is stable whether the
    /// app is bundled or run via `swift run`.
    static func supportBase() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("com.dbrief.app", isDirectory: true)
            .appendingPathComponent("LocalAIPlugin", isDirectory: true)
    }
}

/// In-app proxy implementing the same surface as the former in-process service,
/// forwarding every call to the crash-isolated `dBriefMLHost` helper over a
/// supervised child process.
final class LocalAIPluginService: LocalAIPluginProtocol, Sendable {
    let connection: MLHostConnection
    private let broadcaster = StateBroadcaster()

    /// A fresh subscriber stream each access. The app iterates this once per op
    /// (cancelling it when the op ends), so it must survive re-subscription —
    /// see `StateBroadcaster`.
    nonisolated var stateStream: AsyncStream<LocalAIPluginState> { broadcaster.subscribe() }

    init(connection: MLHostConnection) {
        self.connection = connection
        broadcaster.pump { await connection.stateStream(for: .plugin) }
    }

    convenience init() {
        self.init(connection: MLHostConnection(
            binaryURL: MLHostLocator.binaryURL(),
            supportBase: MLHostLocator.supportBase()))
    }

    func transcribe(fileURL: URL, initialPrompt: String?, whisperConfig: WhisperRuntimeConfig) async throws -> TranscriptionResult {
        try await transcribeWithRetry(path: fileURL.path, prompt: initialPrompt, config: whisperConfig)
    }

    func diarize(fileURL: URL) async throws -> [DiarizedTurn] {
        guard case let .diarizeResult(turns) = try await connection.call(.diarize(path: fileURL.path)) else { return [] }
        return turns
    }

    func analyzeTranscript(_ text: String, outputLanguage: OutputLanguage) async throws -> LocalInsightsResult {
        guard case let .insightsResult(r) = try await connection.call(.analyze(text: text, outputLanguage: outputLanguage)) else {
            throw WireError(kind: .generic, message: "no insights")
        }
        return r
    }

    func analyzeTranscriptStream(_ text: String, outputLanguage: OutputLanguage) async -> AsyncThrowingStream<String, Error> {
        await connection.stream(.analyzeStream(text: text, outputLanguage: outputLanguage))
    }

    func chatStream(systemPrompt: String, userMessage: String) async -> AsyncThrowingStream<String, Error> {
        await connection.stream(.chatStream(systemPrompt: systemPrompt, userMessage: userMessage))
    }

    func copyToClipboard(transcript: String, insights: LocalInsightsResult) async -> String {
        // Formatting is pure + needs the AppKit pasteboard — keep it in-process.
        let markdown = ObsidianFormatter.format(transcript: transcript, insights: insights)
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
        }
        return markdown
    }

    /// Synthesize speech to a WAV at `outputPath` via TTSKit in the helper.
    /// Scaffold only — not yet surfaced in any view. Returns the written file's
    /// path plus duration/sample-rate metadata.
    func synthesizeSpeech(text: String, outputPath: String, voice: String? = nil, language: String? = nil) async throws -> SpeechSynthesisResult {
        guard case let .speechResult(r) = try await connection.call(
            .synthesizeSpeech(text: text, outputPath: outputPath, voice: voice, language: language)
        ) else { throw WireError(kind: .generic, message: "no speech result") }
        return r
    }

    func prepareModelsIfNeeded() async { _ = try? await connection.call(.prepareModels) }
    func downloadWhisperModel(config: WhisperRuntimeConfig) async throws { _ = try await connection.call(.downloadWhisper(config: config)) }

    /// Warm the Whisper model in the helper ahead of transcription. Best-effort:
    /// failures (including a helper crash/OOM) are swallowed; the normal load runs
    /// at transcription time. `refresh` forces an unload+reload to refresh GPU
    /// state after sleep.
    func prewarmWhisper(config: WhisperRuntimeConfig, refresh: Bool = false) async {
        _ = try? await connection.call(.prewarmWhisper(config: config, refresh: refresh))
    }
    func downloadLLMModel() async throws { _ = try await connection.call(.downloadLLM) }
    func isWhisperModelCached(name: String) async -> Bool { (try? await connection.call(.isWhisperCached(name: name))).flatMap(Self.bool) ?? false }
    func isLLMModelCached() async -> Bool { (try? await connection.call(.isLLMCached)).flatMap(Self.bool) ?? false }
    func fetchAvailableWhisperModels(repo: String) async -> [String] {
        guard case let .stringsResult(names) = try? await connection.call(.fetchWhisperModels(repo: repo)) else { return [] }
        return names
    }
    func purgeModels() async throws { _ = try await connection.call(.purgeModels) }
    func purgeWhisperModel() async throws { _ = try await connection.call(.purgeWhisper) }
    func purgeSpeakerKitModel() async throws { _ = try await connection.call(.purgeSpeakerKit) }
    func purgeQwenModel() async throws { _ = try await connection.call(.purgeQwen) }
    func purgeModelsOnMemoryPressure() async { _ = try? await connection.call(.memoryPressurePurge) }
    func forceUnload() async { _ = try? await connection.call(.forceUnload) }

    private static func bool(_ e: MLEvent) -> Bool? { if case let .boolResult(b) = e { b } else { nil } }
}

extension LocalAIPluginService {
    /// Transcribe with one automatic retry in safe mode if the helper crashes
    /// (e.g. a WhisperKit nil-logits trap). The helper auto-relaunches on the
    /// next call. A thrown `WireError` (insufficient memory, audio load) does
    /// not retry.
    func transcribeWithRetry(path: String, prompt: String?, config: WhisperRuntimeConfig) async throws -> TranscriptionResult {
        do {
            return try await runTranscribe(path: path, prompt: prompt, config: config, safeMode: false)
        } catch MLHostError.helperCrashed {
            var safe = config
            safe.computeUnits = .cpuAndGPU   // keep decoder off the ANE
            return try await runTranscribe(path: path, prompt: prompt, config: safe, safeMode: true)
        }
    }

    private func runTranscribe(path: String, prompt: String?, config: WhisperRuntimeConfig, safeMode: Bool) async throws -> TranscriptionResult {
        guard case let .transcriptionResult(r) = try await connection.call(
            .transcribe(path: path, initialPrompt: prompt, config: config, safeMode: safeMode)
        ) else { throw WireError(kind: .generic, message: "no transcription") }
        return r
    }
}
