import Foundation
import Darwin
import Hub
import MLXLMCommon
import Tokenizers
import os
#if canImport(MLX)
import MLX
#endif

actor MLXInsightsService {
    private static let modelID = "mlx-community/gemma-4-e4b-it-4bit"
    // Gemma 4 E4B has a 128K context. With ~4 chars/token this budget is ~25K
    // input tokens, leaving plenty of headroom for the system prompt (~1K) and
    // the 8K output ceiling. Sized to fit a ~3-hour meeting without truncation.
    private static let transcriptCharLimit = 100_000
    // Keep a small intro slice for context, then the full tail. Meetings tend
    // to load substance in the middle and end — truncating by dropping the
    // head preserves that detail.
    private static let transcriptHeadChars = 5_000
    private static let transcriptTailChars = 95_000
    private static let truncationSeparator = "\n\n[...MIDDLE TEXT OMITTED FOR BREVITY...]\n\n"

    private let fileManager = FileManager.default
    private let stateHandler: @Sendable (LocalAIPluginState) -> Void
    private var modelContainer: ModelContainer?
    private let metalLibraryAvailable: Bool
    private var isInferencing = false

    init(stateHandler: @escaping @Sendable (LocalAIPluginState) -> Void) {
        self.stateHandler = stateHandler
        self.metalLibraryAvailable = Self.hasMetalLibrary()
    }

    func prepareModelIfNeeded() async throws {
        _ = try await loadModelContainerIfNeeded()
        await unload()
    }

    func analyzeTranscriptStream(
        _ text: String,
        outputLanguage: AppSettings.OutputLanguage
    ) -> AsyncThrowingStream<String, Error> {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallback = emptyFallbackJSON()
            return AsyncThrowingStream { continuation in
                continuation.yield(fallback)
                continuation.finish()
            }
        }

        let truncatedText = Self.truncateTranscript(text)
        let userPrompt = buildUserPrompt(transcript: truncatedText)
        let systemPrompt = buildSystemPrompt(outputLanguage: outputLanguage)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    self.stateHandler(.analyzing)
                    self.isInferencing = true
                    let container = try await self.loadModelContainerIfNeeded()
                    let session = ChatSession(
                        container,
                        instructions: systemPrompt,
                        generateParameters: self.generationParameters()
                    )

                    var output = ""
                    for try await chunk in session.streamResponse(to: userPrompt) {
                        output += chunk
                        continuation.yield(chunk)
                    }
                    self.isInferencing = false

                    _ = try Self.decodeAndNormalize(output)
                    #if canImport(MLX)
                    Logger.ai.info("MLX memory after inference (stream): \(MLX.Memory.snapshot().description)")
                    #endif

                    await self.unload()
                    continuation.finish()
                } catch {
                    self.isInferencing = false
                    await self.unload()
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                task.cancel()
            }
        }
    }

    func analyzeTranscript(
        _ text: String,
        outputLanguage: AppSettings.OutputLanguage
    ) async throws -> LocalInsightsResult {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LocalInsightsResult(
                titleConcept: "",
                summary: "No transcript content was provided.",
                actionItems: [],
                tags: [],
                sentiment: "Neutral"
            )
        }

        do {
            stateHandler(.analyzing)
            isInferencing = true
            let container = try await loadModelContainerIfNeeded()
            let systemPrompt = buildSystemPrompt(outputLanguage: outputLanguage)
            let session = ChatSession(
                container,
                instructions: systemPrompt,
                generateParameters: generationParameters()
            )

            let truncatedText = Self.truncateTranscript(text)
            let userPrompt = buildUserPrompt(transcript: truncatedText)
            var raw = ""
            for try await chunk in session.streamResponse(to: userPrompt) {
                raw += chunk
            }
            isInferencing = false
            let result = try Self.decodeAndNormalize(raw)
            #if canImport(MLX)
            Logger.ai.info("MLX memory after inference: \(MLX.Memory.snapshot().description)")
            #endif

            await unload()
            return result
        } catch {
            isInferencing = false
            await unload()
            throw error
        }
    }

    /// Stream a chat response for an arbitrary system prompt and user message.
    /// Used by TranscriptChatService for conversational AI over transcripts.
    func chatStream(systemPrompt: String, userMessage: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    self.stateHandler(.analyzing)
                    self.isInferencing = true
                    let container = try await self.loadModelContainerIfNeeded()
                    let session = ChatSession(
                        container,
                        instructions: systemPrompt,
                        generateParameters: self.generationParameters()
                    )
                    for try await chunk in session.streamResponse(to: userMessage) {
                        continuation.yield(chunk)
                    }
                    self.isInferencing = false
                    await self.unload()
                    continuation.finish()
                } catch {
                    self.isInferencing = false
                    await self.unload()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                task.cancel()
            }
        }
    }

    func unload() async {
        guard modelContainer != nil else { return }
        guard !isInferencing else {
            Logger.ai.info("MLX unload skipped — inference in progress")
            return
        }
        modelContainer = nil
        #if canImport(MLX)
        // Clear GPU cache only when no inference is running to avoid deadlocking
        // with MLX's internal eval lock.
        clearGPUCacheIfAvailable()
        Logger.ai.info("MLX memory after unload: \(MLX.Memory.snapshot().description)")
        #endif
    }

    /// Force-release all Metal/GPU resources regardless of inference state.
    /// Called on app termination to prevent orphaned GPU allocations that
    /// keep WindowServer at high GPU utilization until reboot.
    func forceUnload() {
        isInferencing = false
        modelContainer = nil
        #if canImport(MLX)
        MLX.Memory.clearCache()
        // Drain any in-flight Metal command buffers so the GPU is idle
        // before the process exits.
        Stream().synchronize()
        Logger.ai.info("MLX force-unloaded for app termination")
        #endif
    }

    func purgeModels() async throws {
        await unload()
        let base = try llmDownloadBaseURL()
        if fileManager.fileExists(atPath: base.path) {
            try fileManager.removeItem(at: base)
        }
    }

    // MARK: - Private

    private func loadModelContainerIfNeeded() async throws -> ModelContainer {
        guard metalLibraryAvailable else {
            throw NSError(
                domain: "MLXInsightsService",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Local Gemma is unavailable: MLX Metal library is missing in this app bundle. Rebuild/run with SwiftPM resources or use Apple Intelligence/Remote AI engine."
                ]
            )
        }

        if let modelContainer {
            return modelContainer
        }

        // Light memory gate — only block when the system is critically low.
        // MLX allocates via Metal on unified memory; macOS reclaims inactive/compressed
        // pages on demand, so traditional free page counts underestimate availability.
        let requiredMemory: Int64 = 512_000_000 // 512MB truly free
        let hasSufficientMemory = await MainActor.run {
            MemoryPressureMonitor.hasSufficientMemory(requiredBytes: requiredMemory)
        }
        guard hasSufficientMemory else {
            throw NSError(
                domain: "MLXInsightsService",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: "Insufficient memory to load Gemma 4 E4B model. Close other apps or use Remote AI engine instead."
                ]
            )
        }

        // Best-effort release of any stale GPU buffers before allocating Gemma 4.
        clearGPUCacheIfAvailable()

        // Configure MLX memory budget before loading the model.
        // Let MLX manage its own allocation cache (default cacheLimit) to avoid
        // Metal allocation stalls during inference. Only cap the hard ceiling.
        #if canImport(MLX)
        let physicalRAM = ProcessInfo.processInfo.physicalMemory
        let limit = min(Int(Double(physicalRAM) * 0.75), 8 * 1024 * 1024 * 1024)
        MLX.Memory.memoryLimit = limit
        Logger.ai.info("MLX memory limits: memoryLimit=\(limit / 1_073_741_824)GB")
        Logger.ai.info("MLX memory before load: \(MLX.Memory.snapshot().description)")
        #endif

        stateHandler(.downloading(progress: nil, stage: .llmModel))
        let hub = HubApi(downloadBase: try llmDownloadBaseURL())
        let downloader = HubApiDownloader(hub: hub)
        let tokenizerLoader = TransformersTokenizerLoader(
            fallbackChatTemplate: Self.gemma4ChatTemplate
        )
        let container = try await loadModelContainer(
            from: downloader,
            using: tokenizerLoader,
            id: Self.modelID
        )
        self.modelContainer = container
        stateHandler(.analyzing)
        return container
    }

    private func llmDownloadBaseURL() throws -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "dBrief"
        let dir = appSupport
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("LocalAIPlugin", isDirectory: true)
            .appendingPathComponent("MLX", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func buildUserPrompt(transcript: String) -> String {
        """
        Analyze this transcript and produce the JSON response exactly as required by the system instructions.
        Do not copy template phrases. Use only factual details present in the transcript.

        TRANSCRIPT:
        \(transcript)

        INSTRUCTION: Focus on extracting specific names, projects, tools, and deadlines mentioned in the text. Ensure the summary is thorough and covers all discussion topics.
        """
    }

    private func buildSystemPrompt(outputLanguage: AppSettings.OutputLanguage) -> String {
        let languageInstruction: String = {
            switch outputLanguage {
            case .english:
                return "OUTPUT LANGUAGE: ENGLISH (Must translate if transcript is different)."
            case .dutch:
                return "OUTPUT LANGUAGE: DUTCH (Must translate if transcript is different)."
            case .custom(let code):
                return "OUTPUT LANGUAGE: ISO Code \(code.uppercased())."
            case .matchInput:
                return "OUTPUT LANGUAGE: Match the language of the transcript exactly."
            }
        }()

        return """
        You are an expert Senior Executive Assistant. Your goal is to extract structured meeting data from a transcript.

        \(languageInstruction)

        ### RULES
        1. **NO REPETITION:** If a point is made twice, record it once.
        2. **DETAIL:** Do not be vague. Use specific names, project names, tools, and deadlines mentioned in the transcript.
        3. **SUMMARY:** Write a thorough, multi-paragraph summary covering ALL major discussion topics.
        4. **ACTION ITEMS:** Extract ALL action items, even minor ones. Format: "[WHO] to [TASK] [CONTEXT/DEADLINE]".
        5. **TITLE CONCEPT:** Generate a short, 3-6 word descriptive title concept.
        6. **TAGS:** Provide 5-10 single words capturing the key topics discussed.
        7. **SENTIMENT:** One of "Positive", "Neutral", or "Negative" based on the overall tone.
        8. **TRUNCATION:** If you see "[...MIDDLE TEXT OMITTED FOR BREVITY...]", understand that the middle of the transcript was removed due to length constraints. Focus your summary on the available text.

        ### OUTPUT FORMAT (Strict JSON Only)
        {
          "title_concept": "Short Descriptive Title",
          "summary": "A detailed, multi-paragraph summary covering all key topics discussed...",
          "action_items": ["[Person] to [task] [context]", "..."],
          "tags": ["Tag1", "Tag2", "Tag3", "..."],
          "sentiment": "Positive" | "Neutral" | "Negative"
        }
        """
    }

    private func generationParameters() -> GenerateParameters {
        .init(
            maxTokens: 8192,
            temperature: 0.5,
            topP: 0.9,
            repetitionPenalty: 1.05,
            prefillStepSize: 256
        )
    }

    /// Official Gemma 4 turn-based chat template.
    /// mlx-community/gemma-4-*-4bit ships without a `chat_template` in
    /// tokenizer_config.json, which causes mlx-swift-lm to fall back to naïve
    /// text concatenation and produce gibberish. This matches the Unsloth/Google
    /// reference; see
    /// https://huggingface.co/mlx-community/gemma-4-31b-8bit/discussions/1
    private static let gemma4ChatTemplate = "{%- set ns = namespace(prev_message_type=None) -%}{%- set loop_messages = messages -%}{{ bos_token }}{%- if (enable_thinking is defined and enable_thinking) or tools or messages[0]['role'] in ['system', 'developer'] -%}{{ '<|turn>system\\n' }}{%- if enable_thinking is defined and enable_thinking -%}{{ '<|think|>' }}{%- set ns.prev_message_type = 'think' -%}{%- endif -%}{%- if messages[0]['role'] in ['system', 'developer'] -%}{{ messages[0]['content'] | trim }}{%- set loop_messages = messages[1:] -%}{%- endif -%}{{ '<turn|>\\n' }}{%- endif %}{%- for message in loop_messages -%}{%- set ns.prev_message_type = None -%}{%- set role = 'model' if message['role'] == 'assistant' else message['role'] -%}{{ '<|turn>' + role + '\\n' }}{%- if message['content'] is string -%}{%- if role == 'model' -%}{{ message['content'] | trim }}{%- else -%}{{ message['content'] | trim }}{%- endif -%}{%- endif -%}{{ '<turn|>\\n' }}{%- endfor -%}{%- if add_generation_prompt -%}{{ '<|turn>model\\n' }}{%- endif -%}"

    private static func truncateTranscript(_ transcript: String) -> String {
        guard transcript.count > transcriptCharLimit else { return transcript }
        let head = String(transcript.prefix(transcriptHeadChars))
        let tail = String(transcript.suffix(transcriptTailChars))
        return head + truncationSeparator + tail
    }

    static func decodeAndNormalize(_ raw: String) throws -> LocalInsightsResult {
        guard let jsonPayload = extractFirstJSONObject(raw) else {
            let preview = String(raw.prefix(500))
            Logger.ai.error("MLX JSON parse failed. Raw output prefix: \(preview, privacy: .public)")
            throw NSError(domain: "MLXInsightsService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model output did not contain valid JSON object."])
        }
        guard let data = jsonPayload.data(using: .utf8) else {
            throw NSError(domain: "MLXInsightsService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to decode model JSON text as UTF-8."])
        }

        let decoded = try JSONDecoder().decode(LocalInsightsResult.self, from: data)
        let normalizedTags = normalizeTags(decoded.tags)
        let normalizedSentiment = normalizeSentiment(decoded.sentiment)
        let normalizedActionItems = decoded.actionItems.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        return LocalInsightsResult(
            titleConcept: decoded.titleConcept.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            actionItems: normalizedActionItems,
            tags: normalizedTags,
            sentiment: normalizedSentiment
        )
    }

    private static func extractFirstJSONObject(_ input: String) -> String? {
        // Reasoning models (Gemma 4) emit <think>…</think> before the answer.
        // Search for JSON only after the last closing tag to avoid partial matches
        // inside the thinking block.
        let searchIn: String
        if let thinkEnd = input.range(of: "</think>", options: .backwards) {
            searchIn = String(input[thinkEnd.upperBound...])
        } else {
            searchIn = input
        }

        guard let start = searchIn.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var isEscaped = false

        for idx in searchIn[start...].indices {
            let char = searchIn[idx]

            if inString {
                if isEscaped {
                    isEscaped = false
                    continue
                }
                if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }

            if char == "\"" {
                inString = true
                continue
            }

            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(searchIn[start...idx])
                }
            }
        }

        return nil
    }

    private static func normalizeTags(_ tags: [String]) -> [String] {
        var unique: [String] = []
        var seen = Set<String>()
        for tag in tags {
            let cleaned = tag
                .replacingOccurrences(of: #"^#+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let lowered = cleaned.lowercased()
            if !seen.contains(lowered) {
                seen.insert(lowered)
                unique.append(cleaned)
            }
            if unique.count == 10 { break }
        }
        return unique
    }

    private static func normalizeSentiment(_ sentiment: String) -> String {
        switch sentiment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "positive":
            return "Positive"
        case "negative":
            return "Negative"
        default:
            return "Neutral"
        }
    }

    private func clearGPUCacheIfAvailable() {
        guard metalLibraryAvailable else { return }
        #if canImport(MLX)
        MLX.Memory.clearCache()
        #else
        // Fallback no-op when MLX isn't linked.
        typealias ClearCacheFn = @convention(c) () -> Void
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "mlx_metal_clear_cache") {
            let function = unsafeBitCast(symbol, to: ClearCacheFn.self)
            function()
        }
        #endif
    }

    private func emptyFallbackJSON() -> String {
        """
        {
          "title_concept": "",
          "summary": "No transcript content was provided.",
          "action_items": [],
          "tags": [],
          "sentiment": "Neutral"
        }
        """
    }

    private static func hasMetalLibrary() -> Bool {

        var candidates: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("default.metallib"))
            candidates.append(resourceURL.appendingPathComponent("mlx.metallib"))
            candidates.append(resourceURL.appendingPathComponent("Resources/default.metallib"))
            candidates.append(resourceURL.appendingPathComponent("Resources/mlx.metallib"))
        }

        if let executableURL = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executableURL.appendingPathComponent("default.metallib"))
            candidates.append(executableURL.appendingPathComponent("mlx.metallib"))
            candidates.append(executableURL.appendingPathComponent("Resources/default.metallib"))
            candidates.append(executableURL.appendingPathComponent("Resources/mlx.metallib"))
        }

        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - HuggingFace bridging for mlx-swift-lm 3.x Downloader/TokenizerLoader protocols

private struct HubApiDownloader: Downloader {
    let hub: HubApi

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await hub.snapshot(
            from: id,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

private struct TransformersTokenizerLoader: TokenizerLoader {
    let fallbackChatTemplate: String?

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizerBridge(upstream, fallbackChatTemplate: fallbackChatTemplate)
    }
}

private struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    private let fallbackChatTemplate: String?

    init(_ upstream: any Tokenizers.Tokenizer, fallbackChatTemplate: String? = nil) {
        self.upstream = upstream
        self.fallbackChatTemplate = fallbackChatTemplate
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            guard let fallbackChatTemplate else {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
            return try upstream.applyChatTemplate(
                messages: messages,
                chatTemplate: .literal(fallbackChatTemplate),
                addGenerationPrompt: true,
                truncation: false,
                maxLength: nil,
                tools: tools,
                additionalContext: additionalContext
            )
        }
    }
}
