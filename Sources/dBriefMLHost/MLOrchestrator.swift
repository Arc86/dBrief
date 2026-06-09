import Foundation
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
    private var parakeetStateTask: Task<Void, Never>?

    init(emit: @escaping @Sendable (MLChannel, LocalAIPluginState) -> Void) {
        self.emit = emit
        self.whisperService = WhisperKitTranscriptionService { state in emit(.plugin, state) }
        self.insightsService = MLXInsightsService { state in emit(.plugin, state) }
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

    func parakeetTranscribe(path: String, modelVariant: String) async throws -> TranscriptionResult {
        try await mutex.withLock { [self] in
            await whisperService.unload()
            await insightsService.unload()
            return try await parakeetService.transcribe(
                fileURL: URL(fileURLWithPath: path),
                language: nil,
                modelVariant: modelVariant
            )
        }
    }

    // MARK: - Analysis

    func analyze(text: String, outputLanguage: OutputLanguage) async throws -> LocalInsightsResult {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            await whisperService.unload()
            let result = try await insightsService.analyzeTranscript(text, outputLanguage: outputLanguage)
            await insightsService.unload()
            return result
        }
    }

    func analyzeStream(text: String, outputLanguage: OutputLanguage, emitToken: @Sendable (String) -> Void) async throws {
        try await mutex.withLock { [self] in
            defer { emit(.plugin, .idle) }
            await whisperService.unload()
            let upstream = await insightsService.analyzeTranscriptStream(text, outputLanguage: outputLanguage)
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
        emit(.plugin, .idle)
    }

    func forceUnload() async {
        await insightsService.forceUnload()
        await whisperService.unload()
        await parakeetService.unload()
        emit(.plugin, .idle)
    }
}
