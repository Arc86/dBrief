import Foundation
import OSLog
import dBriefWire

/// Owns the three ML services inside the helper process, serializes GPU access
/// with an AsyncMutex, and emits progress state on the appropriate channel.
/// This is the in-helper counterpart of the app's old `LocalAIPluginService`.
actor MLOrchestrator: MLBackend {
    private let emit: @Sendable (MLChannel, LocalAIPluginState) -> Void
    private let mutex = AsyncMutex()

    private let whisperService: WhisperKitTranscriptionService
    private let insightsService: MLXInsightsService
    private let parakeetService: ParakeetTranscriptionService
    private let ttsService: TTSService
    private var parakeetStateTask: Task<Void, Never>?

    init(emit: @escaping @Sendable (MLChannel, LocalAIPluginState) -> Void) {
        self.emit = emit
        self.whisperService = WhisperKitTranscriptionService { state in emit(.plugin, state) }
        self.insightsService = MLXInsightsService { state in emit(.plugin, state) }
        self.ttsService = TTSService { state in emit(.plugin, state) }
        let parakeet = ParakeetTranscriptionService()
        self.parakeetService = parakeet
        self.parakeetStateTask = Task {
            for await state in parakeet.stateStream { emit(.parakeet, state) }
        }
    }

    // MARK: - Transcription

    func transcribe(path: String, initialPrompt: String?, config: WhisperRuntimeConfig, safeMode: Bool) async throws -> TranscriptionResult {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            await insightsService.unload()
            return try await whisperService.transcribe(
                fileURL: URL(fileURLWithPath: path),
                initialPrompt: initialPrompt,
                whisperConfig: config,
                safeMode: safeMode
            )
        }
    }

    func diarize(path: String) async throws -> [DiarizedTurn] {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            await insightsService.unload()
            return try await whisperService.diarize(fileURL: URL(fileURLWithPath: path))
        }
    }

    func parakeetTranscribe(path: String, modelVariant: String, diarize: Bool) async throws -> TranscriptionResult {
        try await mutex.withLock { [self] in
            await whisperService.unload()
            await insightsService.unload()
            let fileURL = URL(fileURLWithPath: path)
            let result = try await parakeetService.transcribe(
                fileURL: fileURL,
                language: nil,
                modelVariant: modelVariant
            )
            guard diarize else { return result }

            // Free the Parakeet model before loading SpeakerKit, then run the
            // shared standalone diarization pass and merge speakers by overlap.
            // Route SpeakerKit's download/diarizing progress to the parakeet
            // channel so a first-time model fetch is visible, not a frozen step.
            await parakeetService.unload()
            do {
                let turns = try await whisperService.diarize(
                    fileURL: fileURL,
                    onState: { [emit] state in emit(.parakeet, state) }
                )
                return SpeakerMerge.merge(result, turns: turns)
            } catch {
                Logger.localAI.error("Parakeet diarization failed: \(error.localizedDescription, privacy: .public) — returning transcript without speakers")
                return result
            }
        }
    }

    // MARK: - Text-to-speech (scaffold)

    func synthesizeSpeech(text: String, outputPath: String, voice: String?, language: String?) async throws -> SpeechSynthesisResult {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            await whisperService.unload()
            await insightsService.unload()
            let result = try await ttsService.synthesize(text: text, outputPath: outputPath, voice: voice, language: language)
            await ttsService.unload()
            return result
        }
    }

    // MARK: - Analysis

    func analyze(text: String, outputLanguage: OutputLanguage, customVocabulary: String) async throws -> LocalInsightsResult {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            await whisperService.unload()
            let result = try await insightsService.analyzeTranscript(text, outputLanguage: outputLanguage, customVocabulary: customVocabulary)
            await insightsService.unload()
            return result
        }
    }

    func analyzeStream(text: String, outputLanguage: OutputLanguage, customVocabulary: String, emitToken: @Sendable (String) -> Void) async throws {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            await whisperService.unload()
            let upstream = await insightsService.analyzeTranscriptStream(text, outputLanguage: outputLanguage, customVocabulary: customVocabulary)
            for try await chunk in upstream { emitToken(chunk) }
            await insightsService.unload()
        }
    }

    func chatStream(systemPrompt: String, userMessage: String, emitToken: @Sendable (String) -> Void) async throws {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            await whisperService.unload()
            let upstream = await insightsService.chatStream(systemPrompt: systemPrompt, userMessage: userMessage)
            for try await chunk in upstream { emitToken(chunk) }
            await insightsService.unload()
        }
    }

    // MARK: - Model management

    func prepareModels() async {
        do {
            try await mutex.withLock { [self] in
                defer { emit(.plugin, .idle) }
                try await whisperService.prepareModelIfNeeded()
                try await insightsService.prepareModelIfNeeded()
            }
        } catch {
            emit(.plugin, .idle)
        }
    }

    func downloadWhisper(config: WhisperRuntimeConfig) async throws {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            await insightsService.unload()
            try await whisperService.prepareModel(config: config)
        }
    }

    func prewarmWhisper(config: WhisperRuntimeConfig, refresh: Bool) async throws {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            // Refresh re-loads to recompile GPU/ANE state after sleep eviction.
            if refresh { await whisperService.unload() }
            // Best-effort: do NOT unload the LLM here — prewarm must not evict an
            // in-use insights/chat model just to warm Whisper.
            try await whisperService.prewarm(config: config)
        }
    }

    func downloadLLM() async throws {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            await whisperService.unload()
            try await insightsService.prepareModelIfNeeded()
        }
    }

    func downloadParakeet(variant: String) async throws {
        try await mutex.withLock { [self] in
            await whisperService.unload()
            await insightsService.unload()
            try await parakeetService.prepareModel(variant: variant)
        }
    }

    func isWhisperCached(name: String) async -> Bool { whisperService.isModelDownloaded(name: name) }
    func isLLMCached() async -> Bool { await insightsService.isModelDownloaded() }
    func isParakeetCached() async -> Bool { parakeetService.isModelDownloaded() }
    func fetchWhisperModels(repo: String) async throws -> [String] {
        try await WhisperKitTranscriptionService.fetchAvailableModels(repo: repo)
    }

    func purgeModels() async throws {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            try await whisperService.purgeModels()
            try await insightsService.purgeModels()
        }
    }

    func purgeWhisper() async throws {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            try await whisperService.purgeModels()
        }
    }

    func purgeSpeakerKit() async throws {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            try await whisperService.purgeSpeakerKitModels()
        }
    }

    func purgeQwen() async throws {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            try await insightsService.purgeModels()
        }
    }

    func purgeParakeet() async throws {
        try await mutex.withLock { [self] in
            try await parakeetService.purgeModels()
        }
    }

    func memoryPressurePurge() async {
        await whisperService.unload()
        await insightsService.unload()
        await parakeetService.unload()
        await ttsService.unload()
        emit(.plugin, .idle)
    }

    func forceUnload() async {
        await insightsService.forceUnload()
        await whisperService.unload()
        await parakeetService.unload()
        await ttsService.unload()
        emit(.plugin, .idle)
    }
}
