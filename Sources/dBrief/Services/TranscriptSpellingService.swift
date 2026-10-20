import Foundation
import OSLog
import dBriefWire
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Corrects spelling/casing of the user's custom-vocabulary terms in a finished
/// transcript using the configured AI engine.
///
/// This replaces the old approach of feeding the vocabulary to Whisper as a
/// decoder prompt — which is unreliable and can silently suppress large parts of
/// the transcript (see `WhisperKitTranscriptionService` notes). OpenAI's own
/// guidance recommends LLM post-processing over prompt injection for proper-noun
/// spelling.
///
/// The LLM only *proposes* `{from, to}` corrections; `VocabularyCorrection.apply`
/// validates them against the vocabulary and rewrites the transcript
/// deterministically, so the model can never drop or reformat content.
actor TranscriptSpellingService {
    private static let log = Logger.ai
    struct Request: Sendable {
        let terms: [String]
        let engine: AppSettings.AIEngine
        let endpoint: Endpoint?
    }
    /// What the correction pass did. Only `.skipped` is worth telling the user
    /// about: the vocabulary was set but could not be applied.
    enum Outcome: Sendable, Equatable {
        /// No vocabulary or an empty transcript, so nothing ran.
        case notNeeded
        /// The engine answered and found nothing to fix.
        case unchanged
        case corrected(Int)
        case cancelled
        case skipped(SkipReason)

        var warning: String? {
            guard case .skipped(let reason) = self else { return nil }
            return reason.message
        }
    }
    enum SkipReason: Sendable, Equatable {
        case noEngine, engineFailed, unreadableAnswer

        var message: String {
            switch self {
            case .noEngine:
                String(localized: "Vocabulary correction skipped: no AI engine is available. Choose one in Settings → AI analysis.")
            case .engineFailed:
                String(localized: "Vocabulary correction skipped: the AI engine didn't respond. The transcript is unchanged.")
            case .unreadableAnswer:
                String(localized: "Vocabulary correction skipped: the AI engine's answer couldn't be read. The transcript is unchanged.")
            }
        }
    }
    struct Correction: Sendable {
        var result: TranscriptionResult
        var outcome: Outcome
    }
    typealias Backend = @Sendable (Request, _ system: String, _ user: String) async throws -> String
    typealias Apply = @Sendable ([SpellingCorrection], [String], TranscriptionResult) -> TranscriptionResult
    private let backend: Backend?
    private let apply: Apply
    private let localPlugin: LocalAIPluginService?
    private let aiService = AIService()

    init(localPlugin: LocalAIPluginService? = nil, backend: Backend? = nil,
         apply: @escaping Apply = { VocabularyCorrection.apply($0, vocabulary: $1, to: $2) }) {
        self.localPlugin = localPlugin
        self.backend = backend
        self.apply = apply
    }

    /// Returns a copy of `result` with vocabulary terms re-spelled, and what
    /// happened. Best-effort: on any failure (no engine, parse error, empty
    /// transcript) the input is returned unchanged with a `.skipped` outcome.
    func correct(_ result: TranscriptionResult, request: Request) async -> Correction {
        guard !Task.isCancelled else { return .init(result: result, outcome: .cancelled) }
        let terms = request.terms
        let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty, !transcript.isEmpty else { return .init(result: result, outcome: .notNeeded) }

        do {
            let raw = try await runEngine(transcript: transcript, request: request)
            try Task.checkCancellation()
            guard let corrections = Self.parseCorrectionList(raw) else {
                Self.log.error("Vocabulary spell-fix skipped: unreadable correction list")
                return .init(result: result, outcome: .skipped(.unreadableAnswer))
            }
            guard !corrections.isEmpty else { return .init(result: result, outcome: .unchanged) }
            try Task.checkCancellation()
            let corrected = apply(corrections, terms, result)
            try Task.checkCancellation()
            Self.log.info("Vocabulary spell-fix applied \(corrections.count) correction(s)")
            return .init(result: corrected, outcome: .corrected(corrections.count))
        } catch is CancellationError {
            return .init(result: result, outcome: .cancelled)
        } catch SpellingError.noEngine {
            Self.log.error("Vocabulary spell-fix skipped: no AI engine available")
            return .init(result: result, outcome: .skipped(.noEngine))
        } catch {
            if Task.isCancelled { return .init(result: result, outcome: .cancelled) }
            Self.log.error("Vocabulary spell-fix skipped after the correction service failed")
            return .init(result: result, outcome: .skipped(.engineFailed))
        }
    }

    // MARK: - Engine routing

    private func runEngine(transcript: String, request: Request) async throws -> String {
        let engine = request.engine

        let system = Self.systemPrompt
        let user = Self.userPrompt(
            terms: request.terms,
            // Apple Intelligence has a ~4K-token window; truncate for it only.
            transcript: engine == .appleIntelligence
                ? UnifiedInsightsPrompt.truncateForFoundationModels(transcript)
                : transcript
        )

        try Task.checkCancellation()
        if let backend { return try await backend(request, system, user) }
        switch engine {
        case .localCLI:
            throw SpellingError.noEngine

        case .qwenLocal:
            guard let plugin = localPlugin else { throw SpellingError.noEngine }
            return try await collect(plugin.chatStream(systemPrompt: system, userMessage: user, stage: .spelling))

        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                let session = LanguageModelSession(instructions: system)
                let response = try await PrivacyTrace.perform(.init(stage: .spelling, data: [.text, .metadata], destination: .local(provider: .appleIntelligence))) {
                    try await session.respond(to: user, options: GenerationOptions(temperature: 0.0))
                }
                return response.content
            }
            #endif
            throw SpellingError.noEngine

        case .remoteEndpoint:
            guard let endpoint = request.endpoint else { throw SpellingError.noEngine }
            return try await collect(aiService.streamChat(systemPrompt: system, userMessage: user, endpoint: endpoint, stage: .spelling))
        }
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var out = ""
        for try await chunk in stream {
            try Task.checkCancellation()
            out += chunk
        }
        return out
    }

    private enum SpellingError: LocalizedError {
        case noEngine
        var errorDescription: String? { String(localized: "No AI engine available for vocabulary correction.") }
    }

    // MARK: - Prompts & parsing

    private static let systemPrompt = """
    You correct speech-to-text spelling mistakes. You are given a list of DOMAIN TERMS the \
    speaker uses and a TRANSCRIPT that may have misspelled or mis-capitalized them.

    Return ONLY a JSON array of corrections, each an object {"from": "...", "to": "..."} where:
    - "from" is text that literally appears in the transcript (exact substring, any casing).
    - "to" is the correct spelling — and MUST be one of the DOMAIN TERMS, verbatim.
    Only include genuine misspellings or mis-capitalizations of the DOMAIN TERMS. Do not change \
    grammar, punctuation, or any words that are not domain terms. If there is nothing to fix, \
    return [].

    Output JSON only, no prose, no code fences.
    """

    static func userPrompt(terms: [String], transcript: String) -> String {
        "DOMAIN TERMS:\n" + terms.joined(separator: "\n") + "\n\nTRANSCRIPT:\n" + transcript
    }

    /// Extracts the first JSON array from `raw` (tolerating prose / code fences)
    /// and decodes it into `[SpellingCorrection]`. Returns `[]` on any failure.
    static func parseCorrections(_ raw: String) -> [SpellingCorrection] {
        parseCorrectionList(raw) ?? []
    }

    /// Like `parseCorrections`, but `nil` when `raw` holds no readable list, so a
    /// garbled answer is told apart from a valid "nothing to fix" (`[]`).
    static func parseCorrectionList(_ raw: String) -> [SpellingCorrection]? {
        guard let json = firstJSONArray(in: raw),
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode([SpellingCorrection].self, from: data)
    }

    /// Returns the substring from the first balanced top-level `[ … ]`, or nil.
    private static func firstJSONArray(in text: String) -> String? {
        guard let start = text.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "[": depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 { return String(text[start...idx]) }
                default: break
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }
}
