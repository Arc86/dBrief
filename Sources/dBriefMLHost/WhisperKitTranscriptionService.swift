import Foundation
import dBriefWire
@preconcurrency import WhisperKit
import SpeakerKit
import OSLog

final class WhisperKitTranscriptionService: @unchecked Sendable {
    private static let modelRepo = "argmaxinc/whisperkit-coreml"

    private let fileManager = FileManager.default
    private let stateHandler: @Sendable (LocalAIPluginState) -> Void
    private var whisperKit: WhisperKit?
    private var loadedConfig: WhisperRuntimeConfig?
    // Cached across calls (like `whisperKit`) so segmented recordings don't
    // rebuild SpeakerKit per 30-min part; dropped in `unload()`.
    private var speakerKit: SpeakerKit?

    init(stateHandler: @escaping @Sendable (LocalAIPluginState) -> Void) {
        self.stateHandler = stateHandler
    }

    // MARK: - Public API

    /// Decode a file to WhisperKit's 16 kHz mono `[Float]` input. Exposed so the
    /// orchestrator can decode once and share the buffer between transcription,
    /// diarization, and the embedding pass.
    func loadAudio(fileURL: URL) throws -> [Float] {
        Logger.localAI.info("Loading audio for Whisper transcription")
        do {
            return try AudioProcessor.loadAudioAsFloatArray(fromPath: fileURL.path)
        } catch {
            Logger.localAI.error("Audio load failed for the requested transcription")
            throw TranscriptionServiceError.audioLoadFailed(error.localizedDescription)
        }
    }

    func transcribe(
        bufferedAudio: [Float]?,
        fileURL: URL,
        audioDuration: TimeInterval?,
        initialPrompt: String?,
        whisperConfig: WhisperRuntimeConfig,
        safeMode: Bool = false
    ) async throws -> dBriefWire.TranscriptionResult {
        Logger.localAI.info("Transcribing with model \(whisperConfig.modelName, privacy: .public)")

        // Memory gate before loading the model
        let modelInfo = WhisperModelInfo.parse(whisperConfig.modelName)
        let requiredMemory: Int64 = Int64(modelInfo.estimatedMemoryMB) * 1_000_000
        let hasSufficientMemory = SystemMemory.hasSufficientMemory(requiredBytes: requiredMemory)
        guard hasSufficientMemory else {
            throw TranscriptionServiceError.insufficientMemory(
                model: modelInfo.displayName,
                requiredGB: String(format: "%.1f", Double(requiredMemory) / 1_000_000_000)
            )
        }

        let whisper = try await loadWhisperKit(config: whisperConfig)
        stateHandler(.transcribing)

        // Live-segment streaming. WhisperKit only forwards the `segmentCallback:`
        // *parameter* of transcribe() on its non-chunked (single ~30s window) path.
        // With VAD chunking — which we always enable — it instead consults the
        // instance `segmentDiscoveryCallback` (see WhisperKit.transcribeWithOptions,
        // which uses `self.segmentDiscoveryCallback` for each chunk). So the parameter
        // is silently dropped for any recording longer than one window, which is why
        // the "Live Transcript" button only ever appeared for very short clips.
        // Setting the instance property here makes live segments fire at any length.
        whisper.segmentDiscoveryCallback = { [stateHandler] segments in
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

        // Build decoding options. Compute units come from the user's setting (applied
        // at model load); here we pin worker count.
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
        // CoreML prediction concurrency. WhisperKit defaults to 16 workers; with VAD
        // chunking that runs many encoder/decoder predictions on the GPU/ANE at once,
        // which on macOS 26 intermittently yields a nil decoder output that WhisperKit
        // force-unwraps (`decoderOutput.logits!`) and traps.
        //
        // This now runs inside the isolated dBriefMLHost process, so such a trap kills
        // only the helper (the app auto-retries once in safe mode) instead of the whole
        // app. The normal path therefore uses higher concurrency for speed; the
        // safe-mode retry serializes to survive a deterministic trap.
        //
        // 8 was validated as stable on macOS 26 (large-v3 turbo); raised to 12
        // (toward WhisperKit's default of 16) since a trap is now recoverable via
        // the crash-isolated helper + safe-mode retry. If the Benchmark tab shows
        // no throughput gain over 8 — or safe-mode retries become frequent —
        // drop this back (it is intentionally its own commit).
        //
        // Safe mode (post-crash retry) keeps the decoder off the ANE via
        // `.cpuAndGPU` (set by the caller), which is where the nil-logits trap
        // lives. With the ANE out of the picture the trap doesn't recur, so the
        // retry no longer needs to serialize to a single worker: 4 workers makes
        // recovery ~2–3× faster (field data: 1 worker = 1.6× realtime vs ~4× at 8)
        // while staying well clear of the concurrency that triggers the trap.
        options.concurrentWorkerCount = safeMode ? 4 : 12

        do {
            let transcribeStart = Date()
            // wkResults type inferred as WhisperKit's TranscriptionResult — kept local to avoid
            // the module/class name collision when naming the type in function signatures.
            let runTranscription = { (decodeOptions: DecodingOptions) async throws in
                if let bufferedAudio {
                    return try await whisper.transcribe(
                        audioArray: bufferedAudio,
                        decodeOptions: decodeOptions
                    )
                }

                Logger.localAI.info("Using incremental Whisper audio loading")
                return try await whisper.transcribe(
                    audioPath: fileURL.path,
                    audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
                    decodeOptions: decodeOptions
                )
            }
            var wkResults = try await runTranscription(options)

            // A custom-vocabulary initialPrompt is fed to Whisper as conditioning
            // ("previous text") tokens. When that domain is unrelated to the audio
            // (e.g. a work-meeting vocabulary applied to a YouTube video), Whisper
            // can emit *blank* output for most windows — the segments still carry
            // time ranges, so the loss is silent, but their text is empty. Detect
            // that collapse and recover by re-transcribing once without the prompt
            // (a no-prompt pass is reliably complete on the same audio).
            // NOTE: this recovery doubles transcription time when it fires. It is
            // dormant today — the app always passes initialPrompt: nil — and only
            // matters for callers that opt into a decoder prompt.
            if !promptTokens.isEmpty {
                // wkResults type is inferred (name collision), so count inline.
                let total = wkResults.reduce(0) { $0 + $1.segments.count }
                let nonEmpty = wkResults.reduce(0) {
                    $0 + $1.segments.filter { !$0.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty }.count
                }
                if total >= 4, Double(nonEmpty) / Double(total) < 0.5 {
                    Logger.localAI.warning(
                        "Initial prompt suppressed transcription (\(nonEmpty)/\(total) segments had text); retrying without prompt"
                    )
                    var noPromptOptions = options
                    noPromptOptions.promptTokens = nil
                    let retry = try await runTranscription(noPromptOptions)
                    let retryNonEmpty = retry.reduce(0) {
                        $0 + $1.segments.filter { !$0.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty }.count
                    }
                    if retryNonEmpty > nonEmpty { wkResults = retry }
                }
            }
            let transcribeDuration = Date().timeIntervalSince(transcribeStart)
            // Logged at .notice so it persists to the unified log (unlike .info), making
            // transcription speed comparable across runs/settings via `log show`. Includes
            // worker count, model, and audio length so the record is self-explanatory.
            let audioSeconds = audioDuration
                ?? bufferedAudio.map { Double($0.count) / 16_000.0 }
                ?? 0
            let speedFactor = audioSeconds > 0 ? audioSeconds / transcribeDuration : 0
            // os_log redacts interpolated strings as <private> by default; mark the
            // (non-sensitive) timing values .public so they appear in the log.
            let durationStr = String(format: "%.1f", transcribeDuration)
            let speedStr = String(format: "%.1f", speedFactor)
            let audioStr = String(format: "%.1f", audioSeconds)
            Logger.localAI.notice(
                "Transcription completed in \(durationStr, privacy: .public)s (\(speedStr, privacy: .public)x realtime) — model=\(whisperConfig.modelName, privacy: .public), workers=\(options.concurrentWorkerCount), audio=\(audioStr, privacy: .public)s"
            )

            // --- Speaker diarization (optional) ---
            // Diarization must be inlined here because wkResults type can only be inferred
            // from the transcribe() return — cannot be named explicitly in a function signature.
            if whisperConfig.diarizationEnabled {
                guard let bufferedAudio else {
                    throw TranscriptionServiceError.audioLoadFailed(
                        "Incremental loading cannot be combined with speaker diarization."
                    )
                }
                stateHandler(.diarizing)
                let diarStart = Date()
                do {
                    let speakerKit = try await loadSpeakerKit()
                    let diarResult = try await speakerKit.diarize(audioArray: bufferedAudio)
                    Logger.localAI.info("Diarization: \(diarResult.speakerCount) speakers detected")

                    // Convert the diarization turns to our wire type.
                    let turns: [DiarizedTurn] = diarResult.segments.compactMap { seg in
                        guard let id = speakerInfoString(seg.speaker) else { return nil }
                        return DiarizedTurn(speakerId: id, start: Double(seg.startTime), end: Double(seg.endTime))
                    }

                    // Build the transcript from WhisperKit's own segments (every one
                    // of them), then overlay speakers by time overlap via
                    // SpeakerMerge.mergePreservingSegments. We do NOT use
                    // SpeakerKit's addSpeakerInfo(strategy: .subsegment) here: it
                    // silently discards any segment lacking word timestamps, and a
                    // custom-vocabulary initialPrompt routinely makes WhisperKit omit
                    // word timings for most segments — which dropped the bulk of the
                    // transcript whenever diarization + a vocabulary prompt were both on.
                    var baseSegments: [dBriefWire.TranscriptionResult.Segment] = []
                    var fullTextParts: [String] = []
                    for result in wkResults {
                        for seg in result.segments {
                            let segText = cleanTranscriptArtifacts(seg.text)
                            guard !segText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else { continue }
                            let wordTimings: [dBriefWire.TranscriptionResult.Word]? = seg.words?.map { w in
                                dBriefWire.TranscriptionResult.Word(
                                    word: w.word,
                                    start: Double(w.start),
                                    end: Double(w.end),
                                    probability: Double(w.probability)
                                )
                            }
                            baseSegments.append(dBriefWire.TranscriptionResult.Segment(
                                start: Double(seg.start),
                                end: Double(seg.end),
                                text: segText,
                                words: wordTimings
                            ))
                            fullTextParts.append(segText)
                        }
                    }
                    let fullText = fullTextParts.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    let base = dBriefWire.TranscriptionResult(text: fullText, segments: baseSegments)
                    let merged = SpeakerMerge.mergePreservingSegments(base, turns: turns)

                    let diarizationDuration = Date().timeIntervalSince(diarStart)
                    return dBriefWire.TranscriptionResult(
                        text: merged.text,
                        segments: merged.segments,
                        speakerCount: merged.speakerCount ?? diarResult.speakerCount,
                        inferenceTime: transcribeDuration,
                        diarizationTime: diarizationDuration
                    )
                } catch {
                    Logger.localAI.error("Diarization failed — continuing without speaker labels")
                }
            }

            // --- Map WhisperKit results to our type (no diarization or diarization failed) ---
            let mappedSegments = wkResults.flatMap { result in
                result.segments.map { seg -> dBriefWire.TranscriptionResult.Segment in
                    let wordTimings: [dBriefWire.TranscriptionResult.Word]? = seg.words?.map {
                        dBriefWire.TranscriptionResult.Word(
                            word: $0.word,
                            start: Double($0.start),
                            end: Double($0.end),
                            probability: Double($0.probability)
                        )
                    }
                    return dBriefWire.TranscriptionResult.Segment(
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
            return dBriefWire.TranscriptionResult(text: fullText, segments: mappedSegments, language: detectedLanguage, inferenceTime: transcribeDuration)
        } catch {
            // Model lifecycle is owned by MLOrchestrator (it unloads after the
            // last segment of a job, and on error); nothing to clean up here.
            throw error
        }
    }

    /// Fetch the list of available model variant names from the given HuggingFace repo.
    static func fetchAvailableModels(repo: String) async throws -> [String] {
        try await WhisperKit.fetchAvailableModels(from: repo)
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

    /// Load the given model and KEEP it resident (no trailing unload). Used to
    /// warm the model ahead of transcription. Reuses the cached instance when the
    /// config already matches (`loadWhisperKit` no-ops).
    func prewarm(config: WhisperRuntimeConfig) async throws {
        _ = try await loadWhisperKit(config: config)
    }

    /// Best-effort on-disk check for whether the named model is cached.
    /// Computes the path without creating directories (unlike
    /// `whisperDownloadBaseURL()`), so a read-only check has no side effects.
    func isModelDownloaded(name: String) -> Bool {
        let base = SupportPaths.localAIPluginBase
            .appendingPathComponent("WhisperKit", isDirectory: true)
        return isModelCached(name: name, downloadBase: base)
    }

    func unload() async {
        await unloadSpeakerKit()
        guard let whisperKit else { return }
        await whisperKit.unloadModels()
        self.whisperKit = nil
        self.loadedConfig = nil
    }

    func unloadSpeakerKit() async {
        guard let speakerKit else { return }
        await speakerKit.unloadModels()
        self.speakerKit = nil
    }

    /// Returns the cached SpeakerKit instance, building it on first use.
    private func loadSpeakerKit() async throws -> SpeakerKit {
        if let speakerKit { return speakerKit }
        let downloadBase = try speakerKitDownloadBaseURL()
        let skConfig = PyannoteConfig(
            downloadBase: downloadBase.path,
            download: true,
            load: true,
            verbose: true
        )
        let sk = try await SpeakerKit(skConfig)
        self.speakerKit = sk
        return sk
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

        // Phase 2: Init WhisperKit with pre-downloaded model (no download, no load).
        // Apply the user's compute-unit choice to the audio encoder and text decoder.
        // WhisperKit otherwise defaults the decoder to the Neural Engine, where some
        // large models (e.g. large-v3 turbo) return nil logits and crash; selecting
        // "Metal GPU" keeps the decoder off the ANE.
        let units = config.computeUnits.mlComputeUnits
        let wkConfig = WhisperKitConfig(
            modelFolder: modelFolder,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: units,
                textDecoderCompute: units
            ),
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
        try SupportPaths.subdirectory("WhisperKit")
    }

    /// Standalone speaker diarization for an already-transcribed recording.
    /// Runs SpeakerKit on the audio and returns raw speaker turns; the caller
    /// maps these onto existing transcript segments by time overlap. Independent
    /// of WhisperKit transcription, so it never touches WhisperKit's
    /// `TranscriptionResult` and avoids the module/class name collision — it only
    /// reads SpeakerKit's own `DiarizationResult.segments`.
    /// - Parameter onState: progress sink. Defaults to the service's own
    ///   `stateHandler` (`.plugin` channel); the Parakeet path passes a sink that
    ///   routes to the `.parakeet` channel so the SpeakerKit model download is
    ///   visible there instead of looking frozen on "Identifying speakers".
    func diarize(
        fileURL: URL,
        onState: (@Sendable (LocalAIPluginState) -> Void)? = nil
    ) async throws -> [DiarizedTurn] {
        Logger.localAI.info("Standalone diarization started")
        return try await diarize(audioArray: try loadAudio(fileURL: fileURL), onState: onState)
    }

    /// Same as `diarize(fileURL:)` on already-decoded 16 kHz mono samples, so a
    /// caller that transcribed the file can reuse its buffer.
    func diarize(
        audioArray: [Float],
        onState: (@Sendable (LocalAIPluginState) -> Void)? = nil
    ) async throws -> [DiarizedTurn] {
        let emitState = onState ?? stateHandler
        let downloadBase = try speakerKitDownloadBaseURL()
        // SpeakerKit downloads Pyannote models on first use with no progress
        // callback of its own; surface an indeterminate "downloading" state when
        // the cache is empty so the UI doesn't appear stuck during the fetch.
        if !speakerKitModelsPresent(at: downloadBase) {
            emitState(.downloading(progress: nil, stage: .speakerKitModel))
        }
        let speakerKit = try await loadSpeakerKit()
        emitState(.diarizing)
        let diarResult = try await speakerKit.diarize(audioArray: audioArray)
        Logger.localAI.info("Diarization: \(diarResult.speakerCount) speakers detected")

        return diarResult.segments.compactMap { seg in
            guard let id = speakerInfoString(seg.speaker) else { return nil }
            return DiarizedTurn(speakerId: id, start: Double(seg.startTime), end: Double(seg.endTime))
        }
    }

    private func speakerKitDownloadBaseURL() throws -> URL {
        try SupportPaths.subdirectory("SpeakerKit")
    }

    /// Coarse check that SpeakerKit models have been downloaded: the cache
    /// directory exists and is non-empty.
    private func speakerKitModelsPresent(at base: URL) -> Bool {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: base.path)
        return !(contents?.isEmpty ?? true)
    }

    private func speakerInfoString(_ speaker: SpeakerInfo) -> String? {
        switch speaker {
        case .speakerId(let id): return "Speaker \(id + 1)"
        case .multiple(let ids): return ids.isEmpty ? nil : "Speaker \(ids[0] + 1)"
        case .noMatch: return nil
        @unknown default: return nil
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

    // Compiled once — these run on every segment of every transcription.
    private static let specialTokenRegex = try! NSRegularExpression(pattern: #"<\|[^|>]+?\|>"#)
    private static let whitespaceRunRegex = try! NSRegularExpression(pattern: #"\s+"#)
    private static let timestampTokenRegex = try! NSRegularExpression(pattern: #"<\|([0-9]+(?:\.[0-9]+)?)\|>"#)

    private func cleanTranscriptArtifacts(_ text: String) -> String {
        let withFormattedTimestamps = formatWhisperTimestampTokens(in: text)
        var range = NSRange(withFormattedTimestamps.startIndex..., in: withFormattedTimestamps)
        let cleaned = Self.specialTokenRegex.stringByReplacingMatches(
            in: withFormattedTimestamps, range: range, withTemplate: " "
        )
        range = NSRange(cleaned.startIndex..., in: cleaned)
        let normalizedWhitespace = Self.whitespaceRunRegex.stringByReplacingMatches(
            in: cleaned, range: range, withTemplate: " "
        )
        return normalizedWhitespace.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    private func formatWhisperTimestampTokens(in text: String) -> String {
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = Self.timestampTokenRegex.matches(in: text, options: [], range: nsRange)
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
