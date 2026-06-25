import Foundation
import OSLog
import dBriefWire
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Generates a spoken-audio summary: AI-rewrites insights into a natural script,
/// synthesizes it to a temp WAV via the TTS helper, then (on Save) transcodes to
/// an m4a sidecar and persists the script. Mirrors `TranscriptChatService`'s
/// engine routing (active engine, falling back to `chatFallbackEngine` for Local
/// CLI). Speaker labels are intentionally omitted — the summary already names people.
@MainActor
@Observable
final class SpokenSummaryService {
    enum Phase: Equatable {
        case idle
        case rewriting
        case preparingVoice(progress: Double?)
        case synthesizing
        case ready(audioURL: URL, script: String)
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle

    private let appSettings: AppSettings
    private let plugin: LocalAIPluginService?
    private let store: SpokenSummaryStore
    private let aiService = AIService()

    /// Temp WAV produced by synthesis, awaiting Save/Discard.
    private var tempAudioURL: URL?
    private var script: String = ""
    private var stateTask: Task<Void, Never>?

    init(appSettings: AppSettings, plugin: LocalAIPluginService?, store: SpokenSummaryStore) {
        self.appSettings = appSettings
        self.plugin = plugin
        self.store = store
    }

    // MARK: - Pipeline

    func generate(insights: RecordingInsights) async {
        discardTemp()
        phase = .rewriting
        do {
            let raw = try await generateScript(insights: insights)
            let cleaned = SpokenSummaryScript.clean(raw)
            guard !cleaned.isEmpty else {
                phase = .failed(message: "The AI returned an empty script.")
                return
            }
            self.script = cleaned

            // Verify plugin before starting state observation.
            guard let plugin else {
                phase = .failed(message: "Local AI plugin not available.")
                return
            }

            // Observe helper download/load progress while synthesizing.
            phase = .preparingVoice(progress: nil)
            observeModelState()

            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("dbrief-spokensummary-\(UUID().uuidString).wav")
            // Assign before calling synthesizeSpeech so any partial file is cleaned up on error.
            self.tempAudioURL = outURL
            phase = .synthesizing
            _ = try await plugin.synthesizeSpeech(
                text: cleaned,
                outputPath: outURL.path,
                voice: nil,
                language: languageCode(appSettings.outputLanguage)
            )
            stopObservingModelState()
            phase = .ready(audioURL: outURL, script: cleaned)
        } catch {
            stopObservingModelState()
            discardTemp()
            phase = .failed(message: error.localizedDescription)
        }
    }

    func discard() {
        discardTemp()
        phase = .idle
    }

    func reset() {
        stopObservingModelState()
        discardTemp()
        script = ""
        phase = .idle
    }

    // MARK: - Save

    func save(for recording: Recording) async throws -> URL {
        guard let tempAudioURL,
              let audioURL = recording.spokenSummaryAudioURL,
              let scriptURL = recording.spokenSummaryScriptURL else {
            phase = .failed(message: SpokenSummaryError.notReady.localizedDescription)
            throw SpokenSummaryError.notReady
        }
        // Capture as locals (Sendable URLs) for the detached closure.
        let wavURL = tempAudioURL
        let m4aURL = audioURL
        do {
            try await Task.detached(priority: .userInitiated) {
                try SpokenSummaryService.transcodeToM4A(from: wavURL, to: m4aURL)
            }.value
            let summary = SpokenSummary(
                script: script,
                audioFileName: audioURL.lastPathComponent,
                voice: nil,
                language: languageCode(appSettings.outputLanguage),
                engine: appSettings.effectiveAIEngine.rawValue,
                generatedAt: Date()
            )
            try await store.save(summary, to: scriptURL)
        } catch {
            phase = .failed(message: error.localizedDescription)
            throw error
        }
        discardTemp()
        phase = .idle
        return audioURL
    }

    // MARK: - Engine routing (mirrors TranscriptChatService)

    private func generateScript(insights: RecordingInsights) async throws -> String {
        let engine = appSettings.effectiveAIEngine == .localCLI
            ? appSettings.chatFallbackEngine
            : appSettings.effectiveAIEngine

        let systemPrompt = appSettings.spokenSummaryPrompt
        let userMessage = insightsInput(insights, truncateForAppleIntelligence: engine == .appleIntelligence)

        switch engine {
        case .localCLI:
            throw SpokenSummaryError.engineUnavailable("Local CLI cannot generate a spoken summary. Choose a chat fallback engine in Settings → AI Analysis.")

        case .qwenLocal:
            guard let plugin else { throw SpokenSummaryError.engineUnavailable("Local AI plugin not available.") }
            let stream = await plugin.chatStream(systemPrompt: systemPrompt, userMessage: userMessage)
            return try await collect(stream)

        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                let session = LanguageModelSession(instructions: systemPrompt)
                let response = try await session.respond(to: userMessage, options: GenerationOptions(temperature: 0.6))
                return response.content
            }
            #endif
            throw SpokenSummaryError.engineUnavailable("Apple Intelligence requires macOS 26 or later.")

        case .remoteEndpoint:
            guard let endpoint = appSettings.effectiveDefaultAIEndpoint else {
                throw SpokenSummaryError.engineUnavailable("No AI endpoint configured. Add one in Settings → AI Analysis.")
            }
            return try await collect(aiService.streamChat(systemPrompt: systemPrompt, userMessage: userMessage, endpoint: endpoint))
        }
    }

    private func insightsInput(_ insights: RecordingInsights, truncateForAppleIntelligence: Bool) -> String {
        var text = "MEETING SUMMARY:\n\(insights.summary)\n"
        if !insights.actionItems.isEmpty {
            text += "\nACTION ITEMS:\n" + insights.actionItems.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return truncateForAppleIntelligence
            ? UnifiedInsightsPrompt.truncateForFoundationModels(text)
            : text
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var out = ""
        for try await chunk in stream { out += chunk }
        return out
    }

    // MARK: - Model-state progress

    private func observeModelState() {
        guard let plugin else { return }
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in plugin.stateStream {
                guard let self else { return }
                if case let .downloading(progress, _) = state {
                    self.phase = .preparingVoice(progress: progress)
                }
            }
        }
    }

    private func stopObservingModelState() {
        stateTask?.cancel()
        stateTask = nil
    }

    // MARK: - Files

    private func discardTemp() {
        if let tempAudioURL { try? FileManager.default.removeItem(at: tempAudioURL) }
        tempAudioURL = nil
    }

    private func languageCode(_ language: OutputLanguage) -> String? {
        switch language {
        case .matchInput: return nil
        case .english: return "en"
        case .dutch: return "nl"
        case .custom(let code): return code.isEmpty ? nil : code
        }
    }

    nonisolated static func transcodeToM4A(from wav: URL, to m4a: URL) throws {
        try? FileManager.default.removeItem(at: m4a)
        let args = ["-y", "-i", wav.path, "-ac", "1", "-c:a", "aac", "-b:a", "96k", m4a.path]
        let process = Process()
        let resolved = FFmpegLocator.resolve()
        if let resolved, resolved != "/usr/bin/env" {
            process.executableURL = URL(fileURLWithPath: resolved)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ffmpeg"] + args
            process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        }
        let stdErr = Pipe()
        process.standardError = stdErr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SpokenSummaryError.transcodeFailed("ffmpeg not found. The app bundle ships ffmpeg; run the built app rather than `swift run`.")
        }
        guard process.terminationStatus == 0 else {
            let data = stdErr.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? "ffmpeg failed"
            Logger.ai.error("SpokenSummaryService: ffmpeg transcode failed — \(stderr, privacy: .public)")
            throw SpokenSummaryError.transcodeFailed(stderr)
        }
    }
}

enum SpokenSummaryError: LocalizedError {
    case engineUnavailable(String)
    case notReady
    case transcodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable(let m): return m
        case .notReady: return "No spoken summary is ready to save."
        case .transcodeFailed(let m): return "Could not save audio: \(m)"
        }
    }
}
