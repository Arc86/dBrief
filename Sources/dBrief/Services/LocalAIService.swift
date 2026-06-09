#if canImport(FoundationModels)
import Foundation
import FoundationModels
import dBriefWire
import os

private let log = Logger.localAI

/// On-device AI using Apple Foundation Models (macOS 26+).
///
/// Uses guided generation (`@Generable`) to produce one structured `LocalInsightsResult`
/// in a single model call — matching the unified contract the Gemma (MLX) and Local CLI
/// engines use. Constrained decoding removes the hand-rolled JSON parsing and regex that
/// previously dropped tags / action items on malformed free-form output.
@available(macOS 26, *)
actor LocalAIService {

    // MARK: Guided-generation schema

    @Generable
    enum Sentiment {
        case positive
        case neutral
        case negative

        /// Canonical capitalized form expected by `LocalInsightsResult` and markdown.
        var canonical: String {
            switch self {
            case .positive: "Positive"
            case .neutral: "Neutral"
            case .negative: "Negative"
            }
        }
    }

    @Generable
    struct MeetingInsights {
        @Guide(description: "A thorough, multi-paragraph summary covering all major topics. Use specific names, project names, tools, and deadlines mentioned in the transcript.")
        var summary: String

        @Guide(description: "Every action item, even minor ones. Each formatted as '[WHO] to [TASK] [CONTEXT/DEADLINE]'.")
        var actionItems: [String]

        @Guide(description: "Five to ten single-word tags capturing the key topics discussed.")
        var tags: [String]

        var sentiment: Sentiment

        @Guide(description: "A short, 3-6 word descriptive title for the meeting.")
        var titleConcept: String
    }

    // MARK: Public API

    /// Runs one guided-generation pass and returns the unified insights result.
    /// Mirrors the Gemma/Local-CLI single-call contract (summary, action items, tags,
    /// sentiment, and an inline title concept).
    func analyzeTranscript(
        _ transcription: String,
        outputLanguage: OutputLanguage
    ) async throws -> LocalInsightsResult {
        try Self.ensureAvailable()

        let truncated = UnifiedInsightsPrompt.truncateForFoundationModels(transcription)
        let instructions = UnifiedInsightsPrompt.systemPromptForGuidedGeneration(outputLanguage: outputLanguage)
        let userPrompt = UnifiedInsightsPrompt.userPrompt(transcript: truncated)

        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 1_500)

        do {
            let response = try await session.respond(
                to: userPrompt,
                generating: MeetingInsights.self,
                options: options
            )
            let insights = response.content
            log.info("Apple Intelligence analysis complete: \(insights.summary.prefix(80), privacy: .public)...")
            return LocalInsightsResult(
                titleConcept: insights.titleConcept,
                summary: insights.summary,
                actionItems: insights.actionItems,
                tags: insights.tags,
                sentiment: insights.sentiment.canonical
            )
        } catch let error as LanguageModelSession.GenerationError {
            throw LocalAIError.generation(Self.describe(error))
        }
    }

    /// Best-effort warm-up so the first real call has lower latency.
    func prewarm() {
        guard Self.isAvailable else { return }
        LanguageModelSession().prewarm()
    }

    // MARK: Availability

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Throws a specific, user-actionable error when the model can't run.
    static func ensureAvailable() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw LocalAIError.unavailable(message(for: reason))
        }
    }

    static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "Apple Intelligence is not supported on this Mac."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off. Enable it in System Settings → Apple Intelligence & Siri, then try again."
        case .modelNotReady:
            return "The Apple Intelligence model is still downloading or not ready yet. Try again shortly."
        @unknown default:
            return "Apple Intelligence is currently unavailable."
        }
    }

    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "The transcript is too long for Apple Intelligence. Try a shorter recording or a different AI engine."
        case .guardrailViolation:
            return "Apple Intelligence blocked this content with its safety guardrails."
        case .unsupportedLanguageOrLocale:
            return "Apple Intelligence does not support this language. Choose a different output language or AI engine."
        default:
            return error.localizedDescription
        }
    }
}

enum LocalAIError: Error, LocalizedError {
    case unavailable(String)
    case generation(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .generation(let message): message
        }
    }
}
#endif
