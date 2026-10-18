import Foundation

/// Prompt identity is independent of the active/automatically selected profile.
enum PromptKind: String, CaseIterable, Hashable, Sendable {
    case summary, actionItems, tags, spokenSummary, voiceStyle

    var title: String {
        switch self {
        case .summary: String(localized: "Summary")
        case .actionItems: String(localized: "Action Items")
        case .tags: String(localized: "Tags & Sentiment")
        case .spokenSummary: String(localized: "Spoken Summary")
        case .voiceStyle: String(localized: "Voice Style")
        }
    }
    var outputContract: String {
        switch self {
        case .summary: "Write the meeting summary as text. Any formatting belongs within the summary text; dBrief controls the outer response structure."
        case .actionItems: "Return actionable commitments as a list, preserving explicitly stated owners and deadlines. Do not invent missing details."
        case .tags: "Preserve the tags and sentiment output contract: an object with tags (array of strings) and sentiment (string)."
        case .spokenSummary: "Write a natural spoken script from saved meeting insights, without headings or bullet markers."
        case .voiceStyle: "Describe vocal tone, pace, and delivery. This instruction controls speech synthesis, not meeting analysis."
        }
    }
    var description: String {
        switch self {
        case .summary: String(localized: "Shape the summary of your recording.")
        case .actionItems: String(localized: "Make commitments and follow-ups easy to find.")
        case .tags: String(localized: "Choose useful topics and describe the conversation’s tone.")
        case .spokenSummary: String(localized: "Write a summary that sounds natural aloud.")
        case .voiceStyle: String(localized: "Guide the tone and pace of the spoken summary.")
        }
    }
    @MainActor var factoryText: String {
        switch self {
        case .summary: AppSettings.defaultSummaryPrompt
        case .actionItems: AppSettings.defaultActionItemsPrompt
        case .tags: AppSettings.defaultTagsPrompt
        case .spokenSummary: AppSettings.defaultSpokenSummaryPrompt
        case .voiceStyle: AppSettings.defaultTTSDeliveryInstruction
        }
    }
    struct Template: Identifiable {
        let name: String
        let text: String
        var id: String { name }
    }
    var templates: [Template] {
        switch self {
        case .summary:
            [.init(name: String(localized: "Concise"), text: "Summarize this meeting in up to five concise bullets. Prioritize decisions, commitments, and unresolved questions. Preserve names and dates. Do not infer missing details. Use the language of the source unless a language is explicitly requested."),
             .init(name: String(localized: "Detailed"), text: "Write detailed meeting notes with sections for Context, Decisions, Next steps, and Open questions. Preserve names, dates, and commitments. Distinguish proposals from agreed decisions. Omit empty sections and small talk. Use the language of the source unless a language is explicitly requested.")]
        case .actionItems:
            [.init(name: String(localized: "With owners and deadlines"), text: "Extract confirmed action items as a bullet list. For each item include the task, owner, and deadline when stated. Mark missing owners or deadlines as not specified. Do not treat suggestions as commitments. Use the source language unless another language is requested.")]
        case .spokenSummary:
            [.init(name: String(localized: "Brief recap"), text: "Write a short spoken recap from these meeting insights. Start with the main outcome, then cover decisions and next steps. Use short sentences and natural transitions. Preserve facts. Do not read headings or bullet markers aloud.")]
        case .tags, .voiceStyle: []
        }
    }
}

enum PromptScope: Hashable, Sendable { case appDefaults, profile(UUID) }
struct PromptIdentity: Hashable, Sendable {
    let kind: PromptKind
    let scope: PromptScope
}
