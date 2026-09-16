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

extension PromptPreviewSample {
    static let examples: [PromptPreviewSample] = [
        example,
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Team stand-up · Example",
              transcript: """
              Maya: The new sign-in flow is ready for review. I will send the pull request to Leo this morning.
              Leo: I can review it before lunch. My dashboard work is blocked because the reporting API is returning incomplete data.
              Nina: I will check the API logs with the platform team today. If we cannot resolve it, we should keep the old dashboard for this release.
              Maya: Agreed. Sign-in can ship independently, so we will not hold it for the dashboard.
              Leo: We still need a decision about the mobile layout. Can we discuss that at tomorrow’s design review?
              Nina: Yes. There is no deadline for the dashboard until we understand the API issue.
              """,
              summary: "The sign-in flow is ready for review and can ship independently. Dashboard work is blocked by incomplete API data; the old dashboard remains the fallback. The mobile layout and dashboard deadline are undecided.",
              actionItems: ["Maya will send Leo the sign-in pull request this morning.", "Leo will review the pull request before lunch.", "Nina will investigate the reporting API with the platform team today.", "Discuss the mobile layout at tomorrow’s design review."]),
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, title: "Customer feedback · Example",
              transcript: """
              Jordan: Our team likes the search feature, but setting up a workspace took nearly an hour. We could not tell which fields were required.
              Priya: Was the problem the instructions or the number of steps?
              Jordan: Mostly the instructions. We also invited a colleague twice because there was no confirmation after the first invitation.
              Priya: That is helpful. I will send a proposed onboarding checklist by Wednesday and log the missing confirmation as a bug.
              Jordan: We can have two new users try the checklist next week. Please keep the export format unchanged; our reporting scripts depend on it.
              Priya: Understood. We have not committed to a release date for the onboarding changes. I will follow up after the test.
              """,
              summary: "The customer values search but finds onboarding unclear and invitation feedback missing. The team will test a new checklist with two users. Export compatibility must be preserved; no release date was promised.",
              actionItems: ["Priya will send an onboarding checklist by Wednesday.", "Priya will log the missing invitation confirmation as a bug.", "Jordan will arrange a checklist test with two new users next week.", "Priya will follow up after the test."]),
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, title: "Project retrospective · Example",
              transcript: """
              Alex: We shipped on time, but the final week involved too much rework. The acceptance criteria changed after testing started.
              Morgan: Pairing helped us catch issues quickly. I would like to keep that for the next project.
              Sam: I disagree with freezing every requirement. We need room to react to customer feedback.
              Alex: Could we require a short impact review for changes after testing starts, rather than block them?
              Sam: Yes, that would work. Let us try it for one project and review the results.
              Morgan: I will draft the impact-review checklist before Monday. We should also reserve a day for end-to-end testing.
              Alex: We agree on the checklist experiment. The extra testing day still needs approval from the project lead. No owner was assigned to seek that approval today.
              """,
              summary: "The team shipped on time but late requirement changes caused rework. Pairing was effective. They agreed to trial an impact review for changes after testing begins. An additional testing day remains a proposal awaiting approval, with no owner assigned.",
              actionItems: ["Morgan will draft the impact-review checklist before Monday.", "Trial the change impact review on the next project and review the results."])
    ]
}
