import Foundation
import dBriefWire

// MARK: - Profile-Resolved Effective Settings

extension AppSettings {
    var activeProfile: MeetingProfile {
        if let automaticProfileId, let profile = profiles.first(where: { $0.id == automaticProfileId }) {
            return profile
        }
        if let profile = profiles.first(where: { $0.id == activeProfileId }) {
            return profile
        }
        if let defaultProfile = profiles.first(where: { $0.preset == .default }) {
            return defaultProfile
        }
        return profiles[0]
    }

    /// Integration settings as a given profile sees them: its TickTick list,
    /// Todoist project and Notion destination overrides on top of the app's. Deliveries resolve with the
    /// profile they were prepared under, never the currently active one, so a
    /// later retry still goes where the meeting's profile sent it. A nil or
    /// deleted profile resolves the app settings.
    func resolvedIntegrations(for profileID: UUID?) -> IntegrationSettings {
        var resolved = integrations
        guard let profileID, let overrides = profiles.first(where: { $0.id == profileID })?.overrides else {
            return resolved
        }
        if let id = overrides.tickTickProjectID {
            resolved.tickTick.projectID = id.isEmpty ? nil : id
            resolved.tickTick.projectName = id.isEmpty ? nil : overrides.tickTickProjectName
        }
        if let id = overrides.todoistProjectID {
            resolved.todoist.projectID = id.isEmpty ? nil : id
            resolved.todoist.projectName = id.isEmpty ? nil : overrides.todoistProjectName
        }
        if let id = overrides.notionParentID, !id.isEmpty {
            resolved.notion.parentID = id
            resolved.notion.parentType = overrides.notionParentType.flatMap(NotionParentType.init(rawValue:)) ?? .page
            resolved.notion.parentName = overrides.notionParentName
        }
        return resolved
    }

    /// `nil` explicitly resolves app defaults, for global tests and app-scope previews.
    func resolvedLocalCLIConfig(for profile: MeetingProfile?) -> LocalCLIConfig {
        var config = localCLIConfig
        config.effort = profile?.overrides.localCLIReasoningEffort ?? config.effort
        return config
    }

    func resolvedCalendarCLIConfig(for profile: MeetingProfile?) -> CalendarCLIConfig {
        calendarCLIConfig.updating(
            effort: profile?.overrides.calendarCLIReasoningEffort ?? calendarCLIConfig.effort)
    }

    var effectiveLocalCLIConfig: LocalCLIConfig {
        resolvedLocalCLIConfig(for: activeProfile)
    }

    var effectiveCalendarCLIConfig: CalendarCLIConfig {
        resolvedCalendarCLIConfig(for: activeProfile)
    }

    var effectiveTranscriptionLanguage: String {
        activeProfile.overrides.transcriptionLanguage ?? transcriptionLanguage
    }

    var effectiveCustomVocabulary: [String] {
        activeProfile.overrides.customVocabulary ?? customVocabulary
    }

    /// Filler-word removal is a global preference (not currently profile-overridable).
    /// Exposed as an `effective…` accessor so call sites stay uniform.
    var effectiveRemoveFillerWords: Bool {
        removeFillerWords
    }

    /// Resolved ignored-segment phrases (built-in defaults + user custom), or empty when the
    /// feature is disabled. Global preference; exposed as `effective…` for call-site uniformity.
    var effectiveIgnoredSegments: Set<String> {
        guard removeIgnoredSegments else { return [] }
        return Set(TranscriptCleanup.defaultIgnoredSegments).union(customIgnoredSegments)
    }

    var effectiveTranscriptionEngine: TranscriptionEngine {
        activeProfile.overrides.transcriptionEngine ?? transcriptionEngine
    }

    var effectiveDefaultTranscriptionEndpoint: Endpoint? {
        if let overrideID = activeProfile.overrides.transcriptionEndpointId,
           let endpoint = transcriptionEndpoints.first(where: { $0.id == overrideID })
        {
            return endpoint
        }
        return defaultTranscriptionEndpoint
    }

    var effectiveAIProcessingEnabled: Bool {
        activeProfile.overrides.aiProcessingEnabled ?? aiProcessingEnabled
    }

    var effectiveAIEngine: AIEngine {
        activeProfile.overrides.aiEngine ?? aiEngine
    }

    var effectiveDefaultAIEndpoint: Endpoint? {
        if let overrideID = activeProfile.overrides.aiEndpointId,
           let endpoint = aiEndpoints.first(where: { $0.id == overrideID })
        {
            return endpoint
        }
        return defaultAIEndpoint
    }

    var effectiveSummaryPrompt: String {
        activeProfile.overrides.summaryPrompt ?? summaryPrompt
    }

    var effectiveActionItemsPrompt: String {
        activeProfile.overrides.actionItemsPrompt ?? actionItemsPrompt
    }

    var effectiveTagsPrompt: String {
        activeProfile.overrides.tagsPrompt ?? tagsPrompt
    }

    var effectiveAutoTranscribe: Bool {
        activeProfile.overrides.autoTranscribe ?? autoTranscribe
    }

    var effectiveAutoSummary: Bool {
        activeProfile.overrides.autoSummary ?? autoSummary
    }

    var effectiveAutoActionItems: Bool {
        activeProfile.overrides.autoActionItems ?? autoActionItems
    }

    var effectiveAutoTags: Bool {
        activeProfile.overrides.autoTags ?? autoTags
    }

    var effectiveAutoLoadCalendarParticipants: Bool {
        activeProfile.overrides.autoLoadCalendarParticipants ?? autoLoadCalendarParticipants
    }

    /// Tasks for a file dropped into a watched folder: the active profile's After
    /// recording choices, like the engine, folders and AI it is processed with.
    var watchedFolderTasks: (transcribe: Bool, summary: Bool, actionItems: Bool, tags: Bool) {
        let transcribe = effectiveAutoTranscribe
        return (transcribe, effectiveAutoSummary && transcribe, effectiveAutoActionItems && transcribe, effectiveAutoTags && transcribe)
    }

    func resolvedAutoLoadCalendarParticipants(for profile: MeetingProfile?) -> Bool {
        profile?.overrides.autoLoadCalendarParticipants ?? autoLoadCalendarParticipants
    }

    var effectiveRecordingFolderURL: URL {
        resolvedFolderURL(
            overridePath: activeProfile.overrides.recordingFolderPath,
            fallback: recordingFolderURL
        )
    }

    /// The app default or any profile uses `engine`, so its setup card must stay visible.
    func usesTranscriptionEngineAnywhere(_ engine: TranscriptionEngine) -> Bool {
        transcriptionEngine == engine || profiles.contains { $0.overrides.transcriptionEngine == engine }
    }

    func usesAIEngineAnywhere(_ engine: AIEngine) -> Bool {
        aiEngine == engine || profiles.contains { $0.overrides.aiEngine == engine }
    }

    /// Every folder auto-delete must sweep: the app's folders plus each profile's
    /// folder overrides, so recordings saved under a non-active profile also age out.
    func retentionFolders(for category: RetentionCategory) -> [URL] {
        var folders = [recordingFolderURL]
        folders += profiles.map { resolvedFolderURL(overridePath: $0.overrides.recordingFolderPath, fallback: recordingFolderURL) }
        if category == .transcripts {
            folders.append(transcriptionFolderURL)
            folders += profiles.map { resolvedFolderURL(overridePath: $0.overrides.transcriptionFolderPath, fallback: transcriptionFolderURL) }
        }
        var seen = Set<String>()
        return folders.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    var effectiveTranscriptionFolderURL: URL {
        resolvedFolderURL(
            overridePath: activeProfile.overrides.transcriptionFolderPath,
            fallback: transcriptionFolderURL
        )
    }

    var effectiveObsidianVaultURL: URL? {
        guard let path = activeProfile.overrides.obsidianVaultPath,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return obsidianVaultURL }

        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return obsidianVaultURL
        }
        return url
    }

    var effectiveObsidianDefaultFolderRelativePath: String {
        activeProfile.overrides.obsidianDefaultFolderRelativePath ?? obsidianDefaultFolderRelativePath
    }

    /// The Whisper helper config, built identically for prewarm and transcription so a
    /// prewarmed model satisfies `loadedConfig == config` in the helper and is reused.
    /// Uses the active profile's language, like every other engine.
    var whisperRuntimeConfig: WhisperRuntimeConfig {
        let language = effectiveTranscriptionLanguage
        return WhisperRuntimeConfig(
            modelName: whisperModelName,
            language: language.isEmpty ? nil : language,
            diarizationEnabled: diarizationEnabled,
            computeUnits: whisperComputeUnits
        )
    }

    /// Pure coercion: a persisted `.outlook` selection is treated as `.disabled`
    /// when no real Azure client ID is configured, so it cannot drive lookups
    /// against the placeholder. Other sources pass through unchanged.
    static func resolveCalendarSource(_ source: CalendarSource, outlookConfigured: Bool) -> CalendarSource {
        if source == .outlook && !outlookConfigured { return .disabled }
        return source
    }

    /// Calendar source to actually use for lookups (coerces stale `.outlook` when unconfigured).
    var effectiveCalendarSource: CalendarSource {
        AppSettings.resolveCalendarSource(calendarSource, outlookConfigured: MicrosoftAuthService.isConfigured)
    }
}
