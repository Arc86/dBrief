import Foundation
@preconcurrency import WhisperKit
import SpeakerKit
import OSLog

final class WhisperKitTranscriptionService: @unchecked Sendable {
    private static let modelRepo = "argmaxinc/whisperkit-coreml"

    private let fileManager = FileManager.default
    private let stateHandler: @Sendable (LocalAIPluginState) -> Void
    private var whisperKit: WhisperKit?
    private var loadedConfig: WhisperRuntimeConfig?

    init(stateHandler: @escaping @Sendable (LocalAIPluginState) -> Void) {
        self.stateHandler = stateHandler
    }

    // MARK: - Public API

    func transcribe(fileURL: URL, initialPrompt: String?, whisperConfig: WhisperRuntimeConfig) async throws -> dBrief.TranscriptionResult {
        Logger.localAI.info("Transcribing: \(fileURL.lastPathComponent, privacy: .public) with model \(whisperConfig.modelName, privacy: .public)")

        // Memory gate before loading the model
        let modelInfo = WhisperModelInfo.parse(whisperConfig.modelName)
        let requiredMemory: Int64 = Int64(modelInfo.estimatedMemoryMB) * 1_000_000
        let hasSufficientMemory = await MainActor.run {
            MemoryPressureMonitor.hasSufficientMemory(requiredBytes: requiredMemory)
        }
        guard hasSufficientMemory else {
            throw TranscriptionServiceError.insufficientMemory(
                model: modelInfo.displayName,
                requiredGB: String(format: "%.1f", Double(requiredMemory) / 1_000_000_000)
            )
        }

        // Load audio as float array — shared between WhisperKit and SpeakerKit
        Logger.localAI.info("Loading audio from \(fileURL.lastPathComponent, privacy: .public)")
        let audioArray: [Float]
        do {
            audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: fileURL.path)
        } catch {
            Logger.localAI.error("Audio load failed: \(error.localizedDescription, privacy: .public)")
            throw TranscriptionServiceError.audioLoadFailed(error.localizedDescription)
        }

        let whisper = try await loadWhisperKit(config: whisperConfig)
        stateHandler(.transcribing)

        // Build decoding options — WhisperKit manages compute units and worker count internally
        let promptTokens = buildPromptTokens(userPrompt: initialPrompt, whisper: whisper)
        var options = DecodingOptions()
        options.language = whisperConfig.language
        options.detectLanguage = whisperConfig.language == nil
        options.task = .transcribe
        options.promptTokens = promptTokens.isEmpty ? nil : promptTokens
        options.temperature = 0
        options.skipSpecialTokens = true
        options.withoutTimestamps = false
        options.wordTimestamps = true
        options.chunkingStrategy = .vad

        do {
            let transcribeStart = Date()
            // wkResults type inferred as WhisperKit's TranscriptionResult — kept local to avoid
            // the module/class name collision when naming the type in function signatures.
            let wkResults = try await whisper.transcribe(
                audioArray: audioArray,
                decodeOptions: options,
                segmentCallback: { [stateHandler] segments in
                    let liveSegments = segments.map { seg in
                        LiveTranscriptSegment(
                            start: Double(seg.start),
                            end: Double(seg.end),
                            text: seg.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        )
                    }
                    if !liveSegments.isEmpty {
                        stateHandler(.newSegments(liveSegments))
                    }
                }
            )
            let transcribeDuration = Date().timeIntervalSince(transcribeStart)
            Logger.localAI.info("Transcription completed in \(String(format: "%.1f", transcribeDuration))s")

            // --- Speaker diarization (optional) ---
            // Diarization must be inlined here because wkResults type can only be inferred
            // from the transcribe() return — cannot be named explicitly in a function signature.
            if whisperConfig.diarizationEnabled {
                stateHandler(.diarizing)
                do {
                    let downloadBase = try speakerKitDownloadBaseURL()
                    let skConfig = PyannoteConfig(
                        downloadBase: downloadBase.path,
                        download: true,
                        load: true,
                        verbose: true
                    )
                    let speakerKit = try await SpeakerKit(skConfig)
                    let diarResult = try await speakerKit.diarize(audioArray: audioArray)
                    Logger.localAI.info("Diarization: \(diarResult.speakerCount) speakers detected")

                    let speakerSegments = diarResult.addSpeakerInfo(to: wkResults, strategy: SpeakerInfoStrategy.subsegment)
                    await speakerKit.unloadModels()

                    var allSegments: [dBrief.TranscriptionResult.Segment] = []
                    var fullTextParts: [String] = []

                    for group in speakerSegments {
                        for seg in group {
                            let speakerId = speakerInfoString(seg.speaker)
                            let wordTimings: [dBrief.TranscriptionResult.Word]? = seg.speakerWords.isEmpty ? nil :
                                seg.speakerWords.map { sw in
                                    dBrief.TranscriptionResult.Word(
                                        word: sw.wordTiming.word,
                                        start: Double(sw.wordTiming.start),
                                        end: Double(sw.wordTiming.end),
                                        probability: nil,
                                        speaker: speakerInfoString(sw.speaker)
                                    )
                                }

                            let segText = cleanTranscriptArtifacts(seg.text)
                            guard !segText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else { continue }

                            allSegments.append(dBrief.TranscriptionResult.Segment(
                                start: Double(seg.startTime),
                                end: Double(seg.endTime),
                                text: segText,
                                words: wordTimings,
                                speaker: speakerId
                            ))
                            fullTextParts.append(segText)
                        }
                    }

                    let fullText = fullTextParts.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    await unload()
                    return dBrief.TranscriptionResult(
                        text: fullText,
                        segments: allSegments,
                        speakerCount: diarResult.speakerCount
                    )
                } catch {
                    Logger.localAI.error("Diarization failed: \(error.localizedDescription, privacy: .public) — continuing without speaker labels")
                }
            }

            // --- Map WhisperKit results to our type (no diarization or diarization failed) ---
            let mappedSegments = wkResults.flatMap { result in
                result.segments.map { seg -> dBrief.TranscriptionResult.Segment in
                    let wordTimings: [dBrief.TranscriptionResult.Word]? = seg.words?.map {
                        dBrief.TranscriptionResult.Word(
                            word: $0.word,
                            start: Double($0.start),
                            end: Double($0.end),
                            probability: Double($0.probability)
                        )
                    }
                    return dBrief.TranscriptionResult.Segment(
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

            Logger.localAI.info("Transcription: segments=\(mappedSegments.count), textLength=\(fullText.count), language=\(detectedLanguage ?? "unknown", privacy: .public)")
            await unload()
            return dBrief.TranscriptionResult(text: fullText, segments: mappedSegments, language: detectedLanguage)
        } catch {
            await unload()
            throw error
        }
    }

    func prepareModelIfNeeded() async throws {
        _ = try await loadWhisperKit(config: .default)
        await unload()
    }

    /// Download + verify the given (user-selected) model, then unload so it
    /// does not stay resident in memory. Unloads on failure too.
    func prepareModel(config: WhisperRuntimeConfig) async throws {
        do {
            _ = try await loadWhisperKit(config: config)
            await unload()
        } catch {
            await unload()
            throw error
        }
    }

    /// Best-effort on-disk check for whether the named model is cached.
    /// Computes the path without creating directories (unlike
    /// `whisperDownloadBaseURL()`), so a read-only check has no side effects.
    func isModelDownloaded(name: String) -> Bool {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "dBrief"
        let base = appSupport
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("LocalAIPlugin", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)
        return isModelCached(name: name, downloadBase: base)
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

    func purgeSpeakerKitModels() async throws {
        let dir = try speakerKitDownloadBaseURL()
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    // MARK: - WhisperKit Loading

    private func loadWhisperKit(config: WhisperRuntimeConfig) async throws -> WhisperKit {
        if let whisperKit, loadedConfig == config {
            return whisperKit
        }
        if whisperKit != nil {
            await unload()
        }

        let downloadBase = try whisperDownloadBaseURL()
        let isCached = isModelCached(name: config.modelName, downloadBase: downloadBase)

        Logger.localAI.info("Loading WhisperKit: model=\(config.modelName, privacy: .public), cached=\(isCached)")

        // Phase 1: Download model with progress (skip if already cached)
        let modelFolder: String
        if isCached {
            stateHandler(.downloading(progress: nil, stage: .whisperModelLoading))
            modelFolder = Self.cachedModelFolder(name: config.modelName, downloadBase: downloadBase, repo: Self.modelRepo).path
        } else {
            stateHandler(.downloading(progress: 0.0, stage: .whisperModel))
            let downloadedURL = try await WhisperKit.download(
                variant: config.modelName,
                downloadBase: downloadBase,
                from: Self.modelRepo,
                progressCallback: { [stateHandler] progress in
                    stateHandler(.downloading(progress: progress.fractionCompleted, stage: .whisperModel))
                }
            )
            modelFolder = downloadedURL.path
        }

        // Phase 2: Init WhisperKit with pre-downloaded model (no download, no load)
        let wkConfig = WhisperKitConfig(
            modelFolder: modelFolder,
            verbose: true,
            logLevel: .info,
            load: false,
            download: false
        )

        let whisper = try await WhisperKit(wkConfig)

        // Phase 3: Set state callback then load models — callback tracks loading progress
        stateHandler(.downloading(progress: nil, stage: .whisperModelLoading))
        whisper.modelStateCallback = { [stateHandler] (_: ModelState?, newState: ModelState) in
            switch newState {
            case .loading, .prewarming:
                stateHandler(.downloading(progress: nil, stage: .whisperModelLoading))
            case .loaded:
                stateHandler(.transcribing)
            default:
                break
            }
        }
        try await whisper.loadModels()

        self.whisperKit = whisper
        self.loadedConfig = config
        Logger.localAI.info("WhisperKit loaded successfully")
        return whisper
    }

    /// The on-disk folder a WhisperKit model is downloaded to. WhisperKit uses the
    /// HuggingFace Hub snapshot layout `<downloadBase>/models/<repo>/<variant>`, not
    /// `<downloadBase>/<variant>` — so the cache check must look there.
    nonisolated static func cachedModelFolder(name: String, downloadBase: URL, repo: String) -> URL {
        var url = downloadBase.appendingPathComponent("models")
        for component in repo.split(separator: "/") {
            url = url.appendingPathComponent(String(component))
        }
        return url.appendingPathComponent(name)
    }

    private func isModelCached(name: String, downloadBase: URL) -> Bool {
        let modelDir = Self.cachedModelFolder(name: name, downloadBase: downloadBase, repo: Self.modelRepo)
        return fileManager.fileExists(atPath: modelDir.path)
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

    private func speakerKitDownloadBaseURL() throws -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "dBrief"
        let dir = appSupport
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("LocalAIPlugin", isDirectory: true)
            .appendingPathComponent("SpeakerKit", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func speakerInfoString(_ speaker: SpeakerInfo) -> String? {
        switch speaker {
        case .speakerId(let id): return "Speaker \(id + 1)"
        case .multiple(let ids): return ids.isEmpty ? nil : "Speaker \(ids[0] + 1)"
        case .noMatch: return nil
        }
    }

    // MARK: - Utilities

    private func buildPromptTokens(userPrompt: String?, whisper: WhisperKit) -> [Int] {
        guard
            let prompt = userPrompt?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            !prompt.isEmpty,
            let tokenizer = whisper.tokenizer
        else {
            return []
        }
        return tokenizer.encode(text: prompt)
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
        return normalizedWhitespace.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
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
            result.replaceSubrange(wholeRange, with: "**[\(formatTimestamp(seconds))]**")
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

enum TranscriptionServiceError: Error, LocalizedError {
    case transcriptionTimeout
    case modelLoadTimeout
    case insufficientMemory(model: String, requiredGB: String)
    case audioLoadFailed(String)
    case diarizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .transcriptionTimeout:
            "Transcription timed out after 10 minutes. Try a smaller model or use Remote transcription."
        case .modelLoadTimeout:
            "Model loading timed out. Check your internet connection and try again."
        case .insufficientMemory(let model, let gb):
            "Insufficient memory to load \(model). Need at least \(gb) GB free. Close other apps or use Remote transcription."
        case .audioLoadFailed(let message):
            "Failed to load audio file: \(message)"
        case .diarizationFailed(let message):
            "Speaker diarization failed: \(message)"
        }
    }
}
