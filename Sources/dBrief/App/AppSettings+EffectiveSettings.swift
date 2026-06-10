import Foundation
import dBriefWire

// MARK: - Profile-Resolved Effective Settings

extension AppSettings {
    var activeProfile: MeetingProfile {
        if let profile = profiles.first(where: { $0.id == activeProfileId }) {
            return profile
        }
        if let defaultProfile = profiles.first(where: { $0.preset == .default }) {
            return defaultProfile
        }
        return profiles[0]
    }

    var effectiveTranscriptionLanguage: String {
        activeProfile.overrides.transcriptionLanguage ?? transcriptionLanguage
    }

    var effectiveWhisperPrompt: String {
        activeProfile.overrides.whisperPrompt ?? whisperPrompt
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

    var effectiveRecordingFolderURL: URL {
        resolvedFolderURL(
            overridePath: activeProfile.overrides.recordingFolderPath,
            fallback: recordingFolderURL
        )
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

    /// The Whisper helper config for the *current raw* settings, built identically
    /// to the transcription path so a prewarmed model satisfies `loadedConfig ==
    /// config` in the helper and is reused (not reloaded). Mirrors the construction
    /// in `RecordingManager.transcribeRecordingAudio` — keep the two in lockstep.
    var whisperRuntimeConfig: WhisperRuntimeConfig {
        WhisperRuntimeConfig(
            modelName: whisperModelName,
            language: transcriptionLanguage.isEmpty ? nil : transcriptionLanguage,
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
