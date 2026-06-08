import Foundation
#if canImport(AppKit)
import AppKit
#endif

actor LocalAIPluginService: LocalAIPluginProtocol {
    nonisolated let stateStream: AsyncStream<LocalAIPluginState>

    private let stateContinuation: AsyncStream<LocalAIPluginState>.Continuation
    private let mutex = AsyncMutex()

    private lazy var whisperService = WhisperKitTranscriptionService { [weak self] state in
        Task { await self?.emitState(state) }
    }

    private lazy var insightsService = MLXInsightsService { [weak self] state in
        Task { await self?.emitState(state) }
    }

    init() {
        var continuation: AsyncStream<LocalAIPluginState>.Continuation!
        self.stateStream = AsyncStream<LocalAIPluginState> { innerContinuation in
            continuation = innerContinuation
        }
        self.stateContinuation = continuation
        continuation.yield(.idle)
    }

    func transcribe(fileURL: URL, initialPrompt: String?, whisperConfig: WhisperRuntimeConfig) async throws -> TranscriptionResult {
        try await mutex.withLock {
            defer { stateContinuation.yield(.idle) }
            await insightsService.unload()
            return try await whisperService.transcribe(fileURL: fileURL, initialPrompt: initialPrompt, whisperConfig: whisperConfig)
        }
    }

    /// Run a standalone speaker-diarization pass on an existing recording's audio
    /// (serialized on the GPU mutex, like transcription).
    func diarize(fileURL: URL) async throws -> [DiarizedTurn] {
        try await mutex.withLock {
            await insightsService.unload()
            return try await whisperService.diarize(fileURL: fileURL)
        }
    }

    func analyzeTranscriptStream(
        _ text: String,
        outputLanguage: AppSettings.OutputLanguage
    ) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    try await mutex.withLock {
                        defer {
                            stateContinuation.yield(.idle)
                        }
                        await whisperService.unload()
                        let upstream = await insightsService.analyzeTranscriptStream(
                            text,
                            outputLanguage: outputLanguage
                        )
                        for try await chunk in upstream {
                            continuation.yield(chunk)
                        }
                        // Aggressive cleanup after stream completes
                        await insightsService.unload()
                    }
                    continuation.finish()
                } catch {
                    // Cleanup on error
                    await whisperService.unload()
                    await insightsService.unload()
                    stateContinuation.yield(.idle)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                task.cancel()
                // Ensure cleanup even on cancellation
                Task { [weak self] in
                    await self?.whisperService.unload()
                    await self?.insightsService.unload()
                    self?.stateContinuation.yield(.idle)
                }
            }
        }
    }

    func analyzeTranscript(
        _ text: String,
        outputLanguage: AppSettings.OutputLanguage
    ) async throws -> LocalInsightsResult {
        try await mutex.withLock {
            defer { stateContinuation.yield(.idle) }
            await whisperService.unload()
            let result = try await insightsService.analyzeTranscript(
                text,
                outputLanguage: outputLanguage
            )
            await insightsService.unload()
            return result
        }
    }

    func copyToClipboard(transcript: String, insights: LocalInsightsResult) async -> String {
        let markdown = ObsidianFormatter.format(transcript: transcript, insights: insights)
        #if canImport(AppKit)
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
        }
        #endif
        return markdown
    }

    /// Stream a chat response using the local Gemma model.
    /// Used by TranscriptChatService for conversational AI over a loaded transcript.
    func chatStream(systemPrompt: String, userMessage: String) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    try await mutex.withLock {
                        defer { stateContinuation.yield(.idle) }
                        await whisperService.unload()
                        let upstream = await insightsService.chatStream(
                            systemPrompt: systemPrompt,
                            userMessage: userMessage
                        )
                        for try await chunk in upstream {
                            continuation.yield(chunk)
                        }
                        await insightsService.unload()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func prepareModelsIfNeeded() async {
        do {
            try await mutex.withLock {
                defer { stateContinuation.yield(.idle) }
                try await whisperService.prepareModelIfNeeded()
                try await insightsService.prepareModelIfNeeded()
            }
        } catch {
            stateContinuation.yield(.idle)
        }
    }

    /// Download the user-selected WhisperKit model (under the GPU mutex).
    func downloadWhisperModel(config: WhisperRuntimeConfig) async throws {
        try await mutex.withLock {
            defer { stateContinuation.yield(.idle) }
            await insightsService.unload()
            try await whisperService.prepareModel(config: config)
        }
    }

    /// Download the local Gemma LLM (under the GPU mutex).
    func downloadLLMModel() async throws {
        try await mutex.withLock {
            defer { stateContinuation.yield(.idle) }
            await whisperService.unload()
            try await insightsService.prepareModelIfNeeded()
        }
    }

    func isWhisperModelCached(name: String) async -> Bool {
        await whisperService.isModelDownloaded(name: name)
    }

    func isLLMModelCached() async -> Bool {
        await insightsService.isModelDownloaded()
    }

    func purgeModels() async throws {
        try await mutex.withLock {
            defer { stateContinuation.yield(.idle) }
            try await whisperService.purgeModels()
            try await insightsService.purgeModels()
        }
    }

    func purgeWhisperModel() async throws {
        try await mutex.withLock {
            defer { stateContinuation.yield(.idle) }
            try await whisperService.purgeModels()
        }
    }

    func purgeSpeakerKitModel() async throws {
        try await mutex.withLock {
            defer { stateContinuation.yield(.idle) }
            try await whisperService.purgeSpeakerKitModels()
        }
    }

    func purgeQwenModel() async throws {
        try await mutex.withLock {
            defer { stateContinuation.yield(.idle) }
            try await insightsService.purgeModels()
        }
    }

    /// Unload models immediately in response to memory pressure (non-throwing).
    /// Called by MemoryPressureMonitor when system is under memory stress.
    func purgeModelsOnMemoryPressure() async {
        // Don't wait for mutex - force immediate unload
        await whisperService.unload()
        await insightsService.unload()
        stateContinuation.yield(.idle)
    }

    /// Force-release all GPU resources for app termination.
    /// Bypasses the inference guard so Metal buffers are freed before _exit().
    func forceUnload() async {
        await insightsService.forceUnload()
        await whisperService.unload()
        stateContinuation.yield(.idle)
    }

    private func emitState(_ state: LocalAIPluginState) {
        stateContinuation.yield(state)
    }
}

actor AsyncMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await lock()
        defer { unlock() }
        return try await operation()
    }

    private func lock() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func unlock() {
        if waiters.isEmpty {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}
