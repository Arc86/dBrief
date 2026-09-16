import Foundation

enum PromptPreferencesError: Error, LocalizedError, Equatable {
    case profileMissing, unsupportedScope, emptyPrompt, conflict
    var errorDescription: String? {
        switch self {
        case .profileMissing: "This profile was deleted. Your draft is still available to copy."
        case .unsupportedScope: "This prompt is only available in app defaults."
        case .emptyPrompt: "Enter instructions or restore the default prompt."
        case .conflict: "This prompt changed elsewhere. Reload the saved version or keep editing and copy your draft."
        }
    }
}

@MainActor
final class PromptPreferencesStore {
    let settings: AppSettings
    init(settings: AppSettings) { self.settings = settings }

    func load(_ identity: PromptIdentity) throws -> PromptSnapshot {
        let shared = settings[keyPath: Self.sharedKey(identity.kind)]
        let value: PromptValue
        let name: String
        switch identity.scope {
        case .appDefaults:
            value = .custom(shared); name = "App defaults"
        case .profile(let id):
            guard let key = Self.overrideKey(identity.kind) else { throw PromptPreferencesError.unsupportedScope }
            guard let profile = settings.profiles.first(where: { $0.id == id }) else { throw PromptPreferencesError.profileMissing }
            value = profile.overrides[keyPath: key].map(PromptValue.custom) ?? .inherited
            name = profile.name
        }
        return PromptSnapshot(identity: identity, value: value, sharedText: shared,
                              factoryText: identity.kind.factoryText, scopeName: name)
    }

    @discardableResult
    func save(_ draft: PromptDraft) throws -> PromptSnapshot {
        let identity = draft.baseline.identity
        let latest = try load(identity)
        guard latest.value == draft.baseline.value else { throw PromptPreferencesError.conflict }
        if (draft.baseline.value == .inherited || draft.value == .inherited), latest.sharedText != draft.baseline.sharedText {
            throw PromptPreferencesError.conflict
        }
        if case .custom(let text) = draft.value, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PromptPreferencesError.emptyPrompt
        }
        switch identity.scope {
        case .appDefaults:
            guard case .custom(let text) = draft.value else { throw PromptPreferencesError.unsupportedScope }
            settings[keyPath: Self.sharedKey(identity.kind)] = text
        case .profile(let id):
            guard let key = Self.overrideKey(identity.kind) else { throw PromptPreferencesError.unsupportedScope }
            guard let index = settings.profiles.firstIndex(where: { $0.id == id }) else { throw PromptPreferencesError.profileMissing }
            let text: String? = switch draft.value { case .inherited: nil; case .custom(let text): text }
            settings.profiles[index].overrides[keyPath: key] = text
        }
        return try load(identity)
    }

    private static func sharedKey(_ kind: PromptKind) -> ReferenceWritableKeyPath<AppSettings, String> {
        switch kind {
        case .summary: \.summaryPrompt
        case .actionItems: \.actionItemsPrompt
        case .tags: \.tagsPrompt
        case .spokenSummary: \.spokenSummaryPrompt
        case .voiceStyle: \.ttsDeliveryInstruction
        }
    }
    private static func overrideKey(_ kind: PromptKind) -> WritableKeyPath<MeetingProfileOverrides, String?>? {
        switch kind {
        case .summary: \.summaryPrompt
        case .actionItems: \.actionItemsPrompt
        case .tags: \.tagsPrompt
        case .spokenSummary, .voiceStyle: nil
        }
    }
}
