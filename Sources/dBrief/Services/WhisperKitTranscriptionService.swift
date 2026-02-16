import Foundation
import WhisperKit

final class WhisperKitTranscriptionService: @unchecked Sendable {
    private static let modelRepo = "argmaxinc/whisperkit-coreml"
    private static let modelName = "openai_whisper-small"
    private static let bilingualPrefix = "This conversation is likely in Dutch and/or English; however, adjust language accordingly."

    private let fileManager = FileManager.default
    private let stateHandler: @Sendable (LocalAIPluginState) -> Void
    private var whisperKit: WhisperKit?

    init(stateHandler: @escaping @Sendable (LocalAIPluginState) -> Void) {
        self.stateHandler = stateHandler
    }

    func transcribe(fileURL: URL, initialPrompt: String?) async throws -> TranscriptionResult {
        // Check available memory before loading Whisper model (~1GB)
        let requiredMemory: Int64 = 2_000_000_000 // 2GB minimum free (1GB model + 1GB buffer)
        let hasSufficientMemory = await MainActor.run {
            MemoryPressureMonitor.hasSufficientMemory(requiredBytes: requiredMemory)
        }
        guard hasSufficientMemory else {
            throw NSError(
                domain: "WhisperKitTranscriptionService",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: "Insufficient memory to load WhisperKit model. Need at least 2GB free memory. Close other apps or use Remote transcription instead."
                ]
            )
        }

        let whisper = try await loadWhisperKit()
        stateHandler(.transcribing)

        // Convert FLAC to WAV if needed for WhisperKit compatibility
        let preparedURL = try await prepareAudioFile(fileURL: fileURL)
        let needsCleanup = preparedURL != fileURL // Track if we created a temp file

        let promptTokens = buildPromptTokens(userPrompt: initialPrompt, whisper: whisper)
        var options = DecodingOptions()
        options.language = nil
        options.detectLanguage = true
        options.task = .transcribe
        options.promptTokens = promptTokens.isEmpty ? nil : promptTokens
        options.concurrentWorkerCount = 1
        options.temperature = 0
        options.skipSpecialTokens = true
        options.withoutTimestamps = false

        do {
            let wkResults = try await whisper.transcribe(
                audioPath: preparedURL.path,
                decodeOptions: options
            )
            let mappedSegments = wkResults.flatMap { result in
                result.segments.map {
                    TranscriptionResult.Segment(
                        start: Double($0.start),
                        end: Double($0.end),
                        text: cleanTranscriptArtifacts($0.text)
                    )
                }
            }
            let rawText = wkResults
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fullText = cleanTranscriptArtifacts(rawText)
            let detectedLanguage = wkResults.first(where: { !$0.language.isEmpty })?.language

            let result = TranscriptionResult(text: fullText, segments: mappedSegments, language: detectedLanguage)

            // Cleanup temporary WAV file if we created one
            if needsCleanup {
                try? fileManager.removeItem(at: preparedURL)
            }

            await unload()
            return result
        } catch {
            // Cleanup temporary WAV file even on error
            if needsCleanup {
                try? fileManager.removeItem(at: preparedURL)
            }
            await unload()
            throw error
        }
    }

    func prepareModelIfNeeded() async throws {
        _ = try await loadWhisperKit()
        await unload()
    }

    func unload() async {
        guard let whisperKit else { return }
        await whisperKit.unloadModels()
        self.whisperKit = nil
    }

    func purgeModels() async throws {
        await unload()
        let base = try whisperDownloadBaseURL()
        if fileManager.fileExists(atPath: base.path) {
            try fileManager.removeItem(at: base)
        }
    }

    // MARK: - Private

    private func prepareAudioFile(fileURL: URL) async throws -> URL {
        let ext = fileURL.pathExtension.lowercased()
        // WhisperKit works best with WAV files, convert FLAC if needed
        guard ext == "flac" else {
            return fileURL
        }

        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("whisperkit-audio-\(UUID().uuidString).wav")

        let ffmpegPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]

        let resolvedPath = ffmpegPaths.first { fileManager.isExecutableFile(atPath: $0) }
        let process = Process()
        if let resolvedPath {
            process.executableURL = URL(fileURLWithPath: resolvedPath)
            process.arguments = [
                "-y",
                "-i", fileURL.path,
                "-ar", "16000",  // 16kHz sample rate for Whisper
                "-ac", "1",       // Mono
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
            throw WhisperKitError.ffmpegNotFound
        }

        guard process.terminationStatus == 0 else {
            let data = stdErr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "ffmpeg failed"
            throw WhisperKitError.conversionFailed(message)
        }

        return outputURL
    }

    private func loadWhisperKit() async throws -> WhisperKit {
        if let whisperKit {
            return whisperKit
        }
        stateHandler(.downloading(progress: nil, stage: .whisperModel))
        let downloadBase = try whisperDownloadBaseURL()
        let config = WhisperKitConfig(
            model: Self.modelName,
            downloadBase: downloadBase,
            modelRepo: Self.modelRepo,
            prewarm: false,
            load: false,
            download: true
        )

        let whisper = try await WhisperKit(config)
        self.whisperKit = whisper
        return whisper
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
