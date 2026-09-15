import Foundation
import dBriefWire

struct PromptPreviewSample: Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let transcript: String
    let summary: String?
    let actionItems: [String]?
    var participants: [String] = []
    var calendarEvent: CalendarEvent? = nil

    static let example = PromptPreviewSample(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Product planning · Example",
        transcript: "Sam: We agreed to focus the next release on easier onboarding. I will draft a shorter setup flow by Friday. Alex: I will gather feedback from three new users. Sam: We have not agreed on a release date yet.",
        summary: "The team agreed to focus the next release on easier onboarding. The release date remains undecided.",
        actionItems: ["Sam will draft a shorter setup flow by Friday.", "Alex will gather feedback from three new users."])
}
struct PromptPreviewRequest: Equatable, Sendable {
    let identity: PromptIdentity
    let draftText: String
    let sample: PromptPreviewSample
    let configuration: PromptExecutionConfiguration
    let outputLanguage: AppSettings.OutputLanguage
    let vocabulary: String
    let summaryGuidance: String
    let actionItemsGuidance: String
    let tagsGuidance: String

    var guidance: InsightsGuidance {
        .init(summary: identity.kind == .summary ? draftText : summaryGuidance,
              actionItems: identity.kind == .actionItems ? draftText : actionItemsGuidance,
              tags: identity.kind == .tags ? draftText : tagsGuidance)
    }
    var shorteningNotice: String? {
        if identity.kind == .voiceStyle { return nil }
        if identity.kind == .spokenSummary {
            guard configuration == .appleIntelligence, let summary = sample.summary, !summary.isEmpty else { return nil }
            let fullInput = SpokenSummaryInput.make(summary: summary, actionItems: sample.actionItems ?? [], truncateForAppleIntelligence: false)
            let sentInput = SpokenSummaryInput.make(summary: summary, actionItems: sample.actionItems ?? [], truncateForAppleIntelligence: true)
            return fullInput != sentInput ? "The saved summary and action items exceed Apple Intelligence’s input budget. The preview keeps the beginning and end." : nil
        }
        let limit = configuration == .appleIntelligence ? UnifiedInsightsPrompt.foundationModelsCharLimit : UnifiedInsightsPrompt.transcriptCharLimit
        if case .remote = configuration { return nil }
        return sample.transcript.count > limit ? "The selected transcript exceeds this engine’s input budget. The production preview keeps the beginning and end." : nil
    }
}
enum PromptPreviewOutput: Equatable, Sendable {
    case summary(String), actionItems([String]), tags([String], sentiment: String), spokenScript(String)
    var text: String {
        switch self {
        case .summary(let text), .spokenScript(let text): text
        case .actionItems(let items): items.isEmpty ? "No action items found." : items.map { "• " + $0 }.joined(separator: "\n")
        case .tags(let tags, let sentiment): "Topics: \(tags.joined(separator: ", "))\nSentiment: \(sentiment)"
        }
    }
}
enum PromptPreviewError: Error, LocalizedError, Equatable {
    case emptyTranscript, missingInsights, unsupportedVoice, contextLimit, analysisFailure(String), failed(String)
    /// Analysis flattens typed failures to strings. Only exact application-owned
    /// messages recover their meaning here; arbitrary backend text is never displayed.
    static func fromAnalysisFailure(_ message: String) -> Self {
        let contextMessages: Set<String> = [
            AIServiceError.contextWindowExceeded.localizedDescription,
            PromptAIError.contextLimit.localizedDescription,
            "The transcript is too long for Apple Intelligence. Try a shorter recording or a different AI engine."
        ]
        if contextMessages.contains(message) { return .contextLimit }
        return .analysisFailure(SettingsErrorSanitizer.details(for: message))
    }

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: "Choose a recording with a transcript, or use the example."
        case .missingInsights: "This recording has no saved summary. Choose the example or a recording with saved insights."
        case .contextLimit: "The sample exceeds the model’s context size. Choose a shorter sample or a model with a larger context, then try again."
        case .unsupportedVoice: "Voice style requires the Qwen 1.7B voice model. Your prompt is preserved."
        case .failed(let message), .analysisFailure(let message): message
        }
    }
}
protocol PromptPreviewing: Sendable {
    func run(_ request: PromptPreviewRequest) async throws -> PromptPreviewOutput
}
