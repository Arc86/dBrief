import Foundation
import CoreML
import Metal
import WhisperKit
import OSLog

final class WhisperKitTranscriptionService: @unchecked Sendable {
    private static let modelRepo = "argmaxinc/whisperkit-coreml"
    private static let bilingualPrefix = "This conversation is likely in Dutch and/or English; however, adjust language accordingly."

    /// Whether a Metal-capable GPU is present on this Mac.
    /// Evaluated once at load time; non-Metal Macs (rare) fall back to Neural Engine only.
    static let hasMetalGPU: Bool = MTLCreateSystemDefaultDevice() != nil

    private let fileManager = FileManager.default
    private let stateHandler: @Sendable (LocalAIPluginState) -> Void
    private var whisperKit: WhisperKit?
    /// Config used to create the currently-loaded WhisperKit instance.
    private var loadedConfig: WhisperRuntimeConfig?

    init(stateHandler: @escaping @Sendable (LocalAIPluginState) -> Void) {
        self.stateHandler = stateHandler
    }

    func transcribe(fileURL: URL, initialPrompt: String?, whisperConfig: WhisperRuntimeConfig) async throws -> TranscriptionResult {
        Logger.localAI.debug("Starting transcription for file: \(fileURL.lastPathComponent, privacy: .public)")

        // Dynamic memory gate: use WhisperModelInfo for model-aware estimation
        let modelInfo = WhisperModelInfo.parse(whisperConfig.modelName)
        let requiredMemory: Int64 = Int64(modelInfo.estimatedMemoryMB) * 1_000_000

        let hasSufficientMemory = await MainActor.run {
            MemoryPressureMonitor.hasSufficientMemory(requiredBytes: requiredMemory)
        }
        guard hasSufficientMemory else {
            throw NSError(
                domain: "WhisperKitTranscriptionService",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: "Insufficient memory to load \(modelInfo.displayName). Need at least \(String(format: "%.1f", Double(requiredMemory) / 1_000_000_000)) GB free. Close other apps or use Remote transcription instead."
                ]
            )
        }

        Logger.localAI.debug("Memory check passed, loading WhisperKit")
        let whisper = try await loadWhisperKit(config: whisperConfig)
        Logger.localAI.debug("WhisperKit loaded, starting transcription")
        stateHandler(.transcribing)

        // Convert FLAC to WAV if needed for WhisperKit compatibility
        let preparedURL = try await prepareAudioFile(fileURL: fileURL)
        let needsCleanup = preparedURL != fileURL
        Logger.localAI.debug("Audio file prepared: \(preparedURL.lastPathComponent, privacy: .public), needsCleanup=\(needsCleanup)")

        let promptTokens = buildPromptTokens(userPrompt: initialPrompt, whisper: whisper)
        var options = DecodingOptions()
        options.language = whisperConfig.language
        options.detectLanguage = whisperConfig.language == nil
        options.task = .transcribe
        options.promptTokens = promptTokens.isEmpty ? nil : promptTokens
        // Dynamic worker count based on available CPU cores, leaving 1 for system
        options.concurrentWorkerCount = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
        options.temperature = 0
        options.skipSpecialTokens = true
        options.withoutTimestamps = false
        options.wordTimestamps = true

        do {
            Logger.localAI.debug("Calling whisper.transcribe with audioPath=\(preparedURL.path, privacy: .public), workers=\(options.concurrentWorkerCount, privacy: .public)")
            let transcribeStart = Date()
            let wkResults = try await whisper.transcribe(
                audioPath: preparedURL.path,
                decodeOptions: options
            )
            let transcribeDuration = Date().timeIntervalSince(transcribeStart)

            // Log timeout warning if transcription took more than 10 minutes
            if transcribeDuration > 600 {
                Logger.localAI.warning("Transcription exceeded 10-minute timeout threshold: \(String(format: "%.1f", transcribeDuration))s")
            }

            Logger.localAI.debug("whisper.transcribe completed in \(String(format: "%.2f", transcribeDuration))s, returned \(wkResults.count) result segments")
            let mappedSegments = wkResults.flatMap { result in
                result.segments.map { seg -> TranscriptionResult.Segment in
                    let wordTimings: [TranscriptionResult.Word]? = {
                        if let words = seg.words {
                            return words.map {
                                TranscriptionResult.Word(
                                    word: $0.word,
                                    start: Double($0.start),
                                    end: Double($0.end),
                                    probability: Double($0.probability ?? 0.0)
                                )
                            }
                        }
                        return nil
                    }()
                    return TranscriptionResult.Segment(
                        start: Double(seg.start),
                        end: Double(seg.end),
                        text: cleanTranscriptArtifacts(seg.text),
                        words: wordTimings
                    )
                }
            }
            let rawText = wkResults
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let fullText = cleanTranscriptArtifacts(rawText)
            let detectedLanguage = wkResults.first(where: { !$0.language.isEmpty })?.language

            Logger.localAI.info("Transcription complete: segments=\(mappedSegments.count), textLength=\(fullText.count), language=\(detectedLanguage ?? "unknown", privacy: .public)")

            let result = TranscriptionResult(text: fullText, segments: mappedSegments, language: detectedLanguage)

            if needsCleanup {
                try? fileManager.removeItem(at: preparedURL)
            }

            await unload()
            return result
        } catch {
            if needsCleanup {
                try? fileManager.removeItem(at: preparedURL)
            }
            await unload()
            throw error
        }
    }

    func prepareModelIfNeeded() async throws {
        _ = try await loadWhisperKit(config: .default)
        await unload()
    }

    func unload() async {
        guard let whisperKit else { return }
        await whisperKit.unloadModels()
        self.whisperKit = nil
        self.loadedConfig = nil
    }

    func purgeModels() async throws {
        await unload()
        let base = try whisperDownloadBaseURL()
        if fileManager.fileExists(atPath: base.path) {
            try fileManager.removeItem(at: base)
        }
    }

    // MARK: - Private

    private func loadWhisperKit(config: WhisperRuntimeConfig) async throws -> WhisperKit {
        // Reuse existing instance if the same config is already loaded
        if let whisperKit, loadedConfig == config {
            Logger.localAI.debug("Reusing already-loaded WhisperKit instance")
            return whisperKit
        }
        // Config changed or not yet loaded — unload any stale instance first
        if whisperKit != nil {
            Logger.localAI.debug("Unloading stale WhisperKit instance before reloading")
            await unload()
        }

        stateHandler(.downloading(progress: nil, stage: .whisperModel))
        let downloadBase = try whisperDownloadBaseURL()
        let computeOpts = buildComputeOptions(for: config)

        Logger.localAI.info(
            "WhisperKit loading: model=\(config.modelName, privacy: .public) computeUnits=\(config.computeUnits.rawValue, privacy: .public) metalGPU=\(Self.hasMetalGPU, privacy: .public)"
        )

        let wkConfig = WhisperKitConfig(
            model: config.modelName,
            downloadBase: downloadBase,
            modelRepo: Self.modelRepo,
            computeOptions: computeOpts,
            prewarm: false,
            load: true,
            download: true
        )

        Logger.localAI.debug("Creating WhisperKit instance with downloadBase=\(downloadBase.path, privacy: .public)")
        let whisper = try await WhisperKit(wkConfig)
        self.whisperKit = whisper
        self.loadedConfig = config
        Logger.localAI.info("WhisperKit instance created and models loaded successfully")
        return whisper
    }

    /// Maps the user's WhisperComputeUnits preference to a CoreML ModelComputeOptions.
    /// On non-Metal hardware the preference is ignored and Neural Engine is used as fallback.
    private func buildComputeOptions(for config: WhisperRuntimeConfig) -> ModelComputeOptions {
        let units: MLComputeUnits
        if Self.hasMetalGPU {
            switch config.computeUnits {
            case .cpuAndNeuralEngine: units = .cpuAndNeuralEngine
            case .cpuAndGPU:         units = .cpuAndGPU
            case .all:               units = .all
            }
        } else {
            // No Metal GPU — fall back to Neural Engine for both encoder and decoder
            units = .cpuAndNeuralEngine
        }
        // Use the same compute units for encoder and decoder for predictable performance.
        // The encoder benefits most from GPU/ANE parallelism; the decoder is autoregressive
        // but still benefits from ANE on Apple Silicon.
        return ModelComputeOptions(audioEncoderCompute: units, textDecoderCompute: units)
    }

    private func prepareAudioFile(fileURL: URL) async throws -> URL {
        let ext = fileURL.pathExtension.lowercased()
        Logger.localAI.debug("prepareAudioFile: fileURL=\(fileURL.lastPathComponent, privacy: .public), extension=\(ext, privacy: .public)")

        guard ext == "flac" else {
            Logger.localAI.debug("File is not FLAC, returning as-is")
            return fileURL
        }

        Logger.localAI.debug("FLAC file detected, converting to WAV")
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("whisperkit-audio-\(UUID().uuidString).wav")

        let ffmpegPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]

        let resolvedPath = ffmpegPaths.first { fileManager.isExecutableFile(atPath: $0) }
        let ffmpegPath = resolvedPath ?? "ffmpeg"
        Logger.localAI.debug("Using ffmpeg at: \(ffmpegPath, privacy: .public)")

        let process = Process()
        if let resolvedPath {
            process.executableURL = URL(fileURLWithPath: resolvedPath)
            process.arguments = [
                "-y",
                "-i", fileURL.path,
                "-ar", "16000",
                "-ac", "1",
                "-f", "wav",
                outputURL.path,
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "ffmpeg",
                "-y",
                "-i", fileURL.path,
                "-ar", "16000",
                "-ac", "1",
                "-f", "wav",
                outputURL.path,
            ]
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]
        }

        let stdErr = Pipe()
        process.standardError = stdErr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Logger.localAI.error("ffmpeg process failed to run: \(error.localizedDescription, privacy: .public)")
            throw WhisperKitError.ffmpegNotFound
        }

        guard process.terminationStatus == 0 else {
            let data = stdErr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "ffmpeg failed"
            Logger.localAI.error("ffmpeg conversion failed: \(message, privacy: .public)")
            throw WhisperKitError.conversionFailed(message)
        }

        Logger.localAI.debug("FLAC to WAV conversion successful: \(outputURL.lastPathComponent, privacy: .public)")
        return outputURL
    }

    private func whisperDownloadBaseURL() throws -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "dBrief"
        let dir = appSupport
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("LocalAIPlugin", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func buildPromptTokens(userPrompt: String?, whisper: WhisperKit) -> [Int] {
        let trimmedUserPrompt = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let promptText: String = {
            if trimmedUserPrompt.isEmpty {
                return Self.bilingualPrefix
            }
            return "\(Self.bilingualPrefix)\n\(trimmedUserPrompt)"
        }()

        guard let tokenizer = whisper.tokenizer else { return [] }
        return tokenizer.encode(text: promptText)
    }

    private func cleanTranscriptArtifacts(_ text: String) -> String {
        let withFormattedTimestamps = formatWhisperTimestampTokens(in: text)
        let cleaned = withFormattedTimestamps.replacingOccurrences(
            of: #"<\|[^|>]+?\|>"#,
            with: " ",
            options: .regularExpression
        )
        let normalizedWhitespace = cleaned.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return normalizedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatWhisperTimestampTokens(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<\|([0-9]+(?:\.[0-9]+)?)\|>"#) else {
            return text
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard
                match.numberOfRanges > 1,
                let wholeRange = Range(match.range(at: 0), in: result),
                let secondsRange = Range(match.range(at: 1), in: result),
                let seconds = Double(result[secondsRange])
            else { continue }

            let replacement = "**[\(formatTimestamp(seconds))]**"
            result.replaceSubrange(wholeRange, with: replacement)
        }
        return result
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

enum WhisperKitError: Error, LocalizedError {
    case ffmpegNotFound
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            "ffmpeg is required to convert FLAC files for transcription. Please install ffmpeg."
        case .conversionFailed(let message):
            "Failed to convert audio file for transcription: \(message)"
        }
    }
}
