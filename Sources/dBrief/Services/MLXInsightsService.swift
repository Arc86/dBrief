import Foundation
import Darwin
import Hub
import MLXLMCommon
#if canImport(MLX)
import MLX
#endif

actor MLXInsightsService {
    private static let modelID = "mlx-community/Qwen2.5-7B-Instruct-4bit"
    private static let transcriptCharLimit = 12_000
    private static let transcriptHeadChars = 6_000
    private static let transcriptTailChars = 6_000
    private static let truncationSeparator = "\n\n[...MIDDLE TEXT OMITTED FOR BREVITY...]\n\n"

    private let fileManager = FileManager.default
    private let stateHandler: @Sendable (LocalAIPluginState) -> Void
    private var modelContainer: ModelContainer?
    private let metalLibraryAvailable: Bool

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
                    stateHandler(.analyzing)
                    let container = try await loadModelContainerIfNeeded()
                    let session = ChatSession(
                        container,
                        instructions: systemPrompt,
                        generateParameters: generationParameters()
                    )

                    var output = ""
                    for try await chunk in session.streamResponse(to: userPrompt) {
                        output += chunk
                        continuation.yield(chunk)
                    }

                    _ = try decodeAndNormalize(output)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
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
                tags: ["tag1", "tag2", "tag3", "tag4", "tag5"],
                sentiment: "Neutral"
            )
        }

        stateHandler(.analyzing)
        let container = try await loadModelContainerIfNeeded()
        let systemPrompt = buildSystemPrompt(outputLanguage: outputLanguage)
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: generationParameters()
        )

        let truncatedText = Self.truncateTranscript(text)
        let userPrompt = buildUserPrompt(transcript: truncatedText)
        let raw = try await session.respond(to: userPrompt)
        return try decodeAndNormalize(raw)
    }

    func unload() async {
        modelContainer = nil
        clearGPUCacheIfAvailable()
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
                    NSLocalizedDescriptionKey: "Local Qwen is unavailable: MLX Metal library is missing in this app bundle. Rebuild/run with SwiftPM resources or use Apple Intelligence/Remote AI engine."
                ]
            )
        }

        if let modelContainer {
            return modelContainer
        }

        // Best-effort release of any stale GPU buffers before allocating Qwen.
        clearGPUCacheIfAvailable()
        stateHandler(.downloading(progress: nil, stage: .llmModel))
        let hub = HubApi(downloadBase: try llmDownloadBaseURL())
        let container = try await loadModelContainer(
            hub: hub,
            id: Self.modelID
        ) { _ in
            // Progress callback available, but mapped as indeterminate in the unified UI for now.
        }
        self.modelContainer = container
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

        INSTRUCTION: Focus on extracting specific project names, client names (e.g., Erasmus, Zuiderland), and deadlines mentioned in the text.
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
        2. **DETAIL:** Do not be vague. Use specific names (e.g., "Zuiderland", "Erasmus"), tools ("Dynamics", "CSDM"), and deadlines.
        3. **ACTION ITEMS:** Must be specific. Format: "[WHO] to [TASK] [CONTEXT]".
        4. **TITLE CONCEPT:** Generate a short, 3-6 word descriptive title concept (do not include the date).
        5. **TAGS:** Single words only. No spaces. Max 5 tags.

        ### OUTPUT FORMAT (Strict JSON Only)
        {
          "title_concept": "Short Descriptive Title",
          "summary": "A detailed, multi-paragraph summary of the meeting...",
          "action_items": ["Action 1", "Action 2"],
          "tags": ["Tag1", "Tag2"],
          "sentiment": "Positive" | "Neutral" | "Negative"
        }
        """
    }

    private func generationParameters() -> GenerateParameters {
        .init(
            maxTokens: 700,
            maxKVSize: 4096,
            temperature: 0.2,
            topP: 1.0,
            prefillStepSize: 256
        )
    }

    private static func truncateTranscript(_ transcript: String) -> String {
        guard transcript.count > transcriptCharLimit else { return transcript }
        let head = String(transcript.prefix(transcriptHeadChars))
        let tail = String(transcript.suffix(transcriptTailChars))
        return head + truncationSeparator + tail
    }

    private func decodeAndNormalize(_ raw: String) throws -> LocalInsightsResult {
        guard let jsonPayload = extractFirstJSONObject(raw) else {
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

    private func extractFirstJSONObject(_ input: String) -> String? {
        guard let start = input.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var isEscaped = false

        for idx in input[start...].indices {
            let char = input[idx]

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
                    return String(input[start...idx])
                }
            }
        }

        return nil
    }

    private func normalizeTags(_ tags: [String]) -> [String] {
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
            if unique.count == 5 { break }
        }

        while unique.count < 5 {
            unique.append("tag\(unique.count + 1)")
        }
        return unique
    }

    private func normalizeSentiment(_ sentiment: String) -> String {
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
          "tags": ["tag1", "tag2", "tag3", "tag4", "tag5"],
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
