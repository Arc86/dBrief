import Foundation
import SwiftUI

@MainActor
@Observable
final class AppSettings {
    // MARK: - Storage Keys

    enum Keys {
        static let recordingFolderBookmark = "recordingFolderBookmark"
        static let transcriptionFolderBookmark = "transcriptionFolderBookmark"
        static let obsidianVaultBookmark = "obsidianVaultBookmark"
        static let autoTranscribe = "autoTranscribe"
        static let autoSummary = "autoSummary"
        static let autoActionItems = "autoActionItems"
        static let autoTags = "autoTags"
        static let callDetectionEnabled = "callDetectionEnabled"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let autoRecordCalls = "autoRecordCalls"
        static let disabledCallApps = "disabledCallApps"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let useBuiltInTranscription = "useBuiltInTranscription"
        static let transcriptionEngine = "transcriptionEngine"
        static let useBuiltInAI = "useBuiltInAI"
        static let aiEngine = "aiEngine"
        static let outputLanguageMode = "outputLanguageMode"
        static let outputLanguageCustomCode = "outputLanguageCustomCode"
        static let audioSampleRate = "audioSampleRate"
        static let audioBitRate = "audioBitRate"
        static let audioInputDeviceUID = "audioInputDeviceUID"
        static let whisperPrompt = "whisperPrompt"
        static let transcriptionEndpoints = "transcriptionEndpoints"
        static let aiEndpoints = "aiEndpoints"
        static let defaultTranscriptionEndpointId = "defaultTranscriptionEndpointId"
        static let defaultAIEndpointId = "defaultAIEndpointId"
        static let dismissedCallAppPIDs = "dismissedCallAppPIDs"
        static let summaryPrompt = "summaryPrompt"
        static let actionItemsPrompt = "actionItemsPrompt"
        static let tagsPrompt = "tagsPrompt"
        static let remoteChunkingEnabled = "remoteChunkingEnabled"
        static let remoteChunkMaxUploadMB = "remoteChunkMaxUploadMB"
        static let remoteChunkOverlapSeconds = "remoteChunkOverlapSeconds"
        static let remoteChunkRetryCount = "remoteChunkRetryCount"
        static let obsidianEnabled = "obsidianEnabled"
        static let obsidianDefaultFolderRelativePath = "obsidianDefaultFolderRelativePath"
        static let integrationSettings = "integrationSettings"
        static let showDockIcon = "showDockIcon"
        static let profiles = "profiles"
        static let activeProfileId = "activeProfileId"
        static let powerUserMode = "powerUserMode"
        static let obsidianIncludeTranscript = "obsidianIncludeTranscript"
    }

    // MARK: - Recording

    var recordingFolderURL: URL {
        didSet { saveBookmark(for: recordingFolderURL, key: Keys.recordingFolderBookmark) }
    }

    var transcriptionFolderURL: URL {
        didSet { saveBookmark(for: transcriptionFolderURL, key: Keys.transcriptionFolderBookmark) }
    }

    // MARK: - Integrations (Obsidian)

    var obsidianEnabled: Bool {
        didSet { UserDefaults.standard.set(obsidianEnabled, forKey: Keys.obsidianEnabled) }
    }

    var obsidianVaultURL: URL? {
        didSet { saveBookmark(for: obsidianVaultURL, key: Keys.obsidianVaultBookmark) }
    }

    /// Relative path inside the vault for default output ("" means vault root)
    var obsidianDefaultFolderRelativePath: String {
        didSet {
            UserDefaults.standard.set(
                obsidianDefaultFolderRelativePath,
                forKey: Keys.obsidianDefaultFolderRelativePath
            )
        }
    }

    var integrations: IntegrationSettings {
        didSet { saveIntegrationSettings(integrations) }
    }

    var notionToken: String {
        didSet { KeychainHelper.set(notionToken, for: .notion) }
    }

    var evernoteToken: String {
        didSet { KeychainHelper.set(evernoteToken, for: .evernote) }
    }

    var googleKeepToken: String {
        didSet { KeychainHelper.set(googleKeepToken, for: .googleKeep) }
    }

    var oneNoteToken: String {
        didSet { KeychainHelper.set(oneNoteToken, for: .oneNote) }
    }

    // MARK: - Post-Recording Defaults

    var autoTranscribe: Bool {
        didSet { UserDefaults.standard.set(autoTranscribe, forKey: Keys.autoTranscribe) }
    }

    var autoSummary: Bool {
        didSet { UserDefaults.standard.set(autoSummary, forKey: Keys.autoSummary) }
    }

    var autoActionItems: Bool {
        didSet { UserDefaults.standard.set(autoActionItems, forKey: Keys.autoActionItems) }
    }

    var autoTags: Bool {
        didSet { UserDefaults.standard.set(autoTags, forKey: Keys.autoTags) }
    }

    // MARK: - Transcription Language

    enum TranscriptionEngine: String, CaseIterable, Codable, Hashable, Sendable {
        case appleSpeech
        case localWhisper
        case remoteEndpoint

        var displayName: String {
            switch self {
            case .appleSpeech: "Apple Speech"
            case .localWhisper: "Local Whisper"
            case .remoteEndpoint: "Remote Endpoint"
            }
        }
    }

    enum AIEngine: String, CaseIterable, Codable, Hashable, Sendable {
        case appleIntelligence
        case qwenLocal
        case remoteEndpoint

        var displayName: String {
            switch self {
            case .appleIntelligence: "Apple Intelligence"
            case .qwenLocal: "Qwen3 4B Local"
            case .remoteEndpoint: "Remote Endpoint"
            }
        }
    }

    enum OutputLanguage: Sendable, Equatable {
        case matchInput
        case english
        case dutch
        case custom(String)

        var displayName: String {
            switch self {
            case .matchInput: "Match Transcript"
            case .english: "English"
            case .dutch: "Dutch"
            case .custom(let code): "Custom (\(code.uppercased()))"
            }
        }

        fileprivate var modeStorageValue: String {
            switch self {
            case .matchInput: "matchInput"
            case .english: "english"
            case .dutch: "dutch"
            case .custom: "custom"
            }
        }
    }

    /// Preferred transcription engine (Apple Speech, Local Whisper, or remote endpoint).
    var transcriptionEngine: TranscriptionEngine {
        didSet { UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) }
    }

    /// Preferred AI engine (Apple Intelligence, local Qwen model, or remote endpoint).
    var aiEngine: AIEngine {
        didSet { UserDefaults.standard.set(aiEngine.rawValue, forKey: Keys.aiEngine) }
    }

    /// Preferred language for local Qwen insights output.
    var outputLanguage: OutputLanguage {
        didSet {
            UserDefaults.standard.set(outputLanguage.modeStorageValue, forKey: Keys.outputLanguageMode)
            if case .custom(let code) = outputLanguage {
                UserDefaults.standard.set(code, forKey: Keys.outputLanguageCustomCode)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.outputLanguageCustomCode)
            }
        }
    }

    /// Sample rate for output audio (default 16000 Hz, good for speech)
    var audioSampleRate: Int {
        didSet { UserDefaults.standard.set(audioSampleRate, forKey: Keys.audioSampleRate) }
    }

    /// AAC bit rate (default 128000 bps)
    var audioBitRate: Int {
        didSet { UserDefaults.standard.set(audioBitRate, forKey: Keys.audioBitRate) }
    }

    /// Audio input device UID (empty string = system default)
    var audioInputDeviceUID: String {
        didSet { UserDefaults.standard.set(audioInputDeviceUID, forKey: Keys.audioInputDeviceUID) }
    }

    /// Show the app icon in the Dock
    var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: Keys.showDockIcon)
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        }
    }

    /// Reveals advanced settings and features across all tabs
    var powerUserMode: Bool {
        didSet { UserDefaults.standard.set(powerUserMode, forKey: Keys.powerUserMode) }
    }

    /// Include full transcript in Obsidian/Markdown output (default off to keep notes concise)
    var obsidianIncludeTranscript: Bool {
        didSet { UserDefaults.standard.set(obsidianIncludeTranscript, forKey: Keys.obsidianIncludeTranscript) }
    }

    /// Empty string means auto-detect, otherwise an ISO 639-1 language code (e.g. "en", "nl", "de")
    var transcriptionLanguage: String {
        didSet { UserDefaults.standard.set(transcriptionLanguage, forKey: Keys.transcriptionLanguage) }
    }

    /// Custom vocabulary/context hint for Whisper (initial_prompt parameter). Helps with proper nouns, acronyms, etc.
    var whisperPrompt: String {
        didSet { UserDefaults.standard.set(whisperPrompt, forKey: Keys.whisperPrompt) }
    }

    // MARK: - AI Prompts

    static let defaultSummaryPrompt = """
        You are an assistant that summarizes meeting transcriptions. \
        Provide a detailed, multi-paragraph summary of the key discussion points, decisions, and outcomes. \
        Cover all major topics discussed in the meeting thoroughly. \
        Do not use conversational filler, just provide the summary directly. \
        Always respond in the exact same language as the transcription.
        """

    static let defaultActionItemsPrompt = """
        You are an assistant that extracts action items from meeting transcriptions. \
        List each action item as a separate line starting with "- ". \
        Include who is responsible if mentioned. \
        OUTPUT ONLY THE LIST ITSELF. DO NOT include any introductory text, markdown code blocks, or conversational filler. \
        Always respond in the exact same language as the transcription.
        """

    static let defaultTagsPrompt = """
        You are an assistant that analyzes meeting transcriptions. \
        Output a JSON object with two fields: \
        "tags" (array of 3-7 relevant topic tags, lowercase, no # prefix) and \
        "sentiment" (one of: "positive", "neutral", "negative", "mixed"). \
        Only output valid JSON, nothing else. \
        Always respond in the exact same language as the transcription.
        """

    static let teamMeetingWhisperPrompt =
        "Team standup, sprint, backlog, blocker, follow-up, ETA, Jira, PR, release, roadmap, architecture."

    static let teamMeetingSummaryPrompt =
        "Summarize this internal team meeting in concise bullet points. Include: decisions, progress updates, blockers, and next steps. Keep tone informal and practical. Always respond in the exact same language as the transcription."

    static let teamMeetingActionItemsPrompt =
        "Extract concrete action items from this team meeting. Output bullet lines beginning with '- '. Include owner if mentioned and due date if mentioned. Keep wording short. Always respond in the exact same language as the transcription."

    static let teamMeetingTagsPrompt =
        "Return valid JSON only: {\"tags\": [...], \"sentiment\": \"...\"}. Tags should reflect internal collaboration topics (planning, delivery, blockers, risks, dependencies). Always respond in the exact same language as the transcription."

    static let salesMeetingWhisperPrompt =
        "Customer, contract, pricing, procurement, renewal, objections, competitor, timeline, stakeholder, action item, follow-up."

    static let salesMeetingSummaryPrompt =
        "Create a formal customer-facing sales meeting summary. Prioritize factual accuracy, commitments, risks, and agreed commercial points. Use clear bullet points. Always respond in the exact same language as the transcription."

    static let salesMeetingActionItemsPrompt =
        "Extract precise action items for sales follow-up. Output bullet lines beginning with '- '. Include owner, expected outcome, and date when available. Be exact and unambiguous. Always respond in the exact same language as the transcription."

    static let salesMeetingTagsPrompt =
        "Return valid JSON only: {\"tags\": [...], \"sentiment\": \"...\"}. Tags should focus on deal stage, customer needs, objections, budget, timeline, decision process, and next steps. Always respond in the exact same language as the transcription."

    var summaryPrompt: String {
        didSet { UserDefaults.standard.set(summaryPrompt, forKey: Keys.summaryPrompt) }
    }

    var actionItemsPrompt: String {
        didSet { UserDefaults.standard.set(actionItemsPrompt, forKey: Keys.actionItemsPrompt) }
    }

    var tagsPrompt: String {
        didSet { UserDefaults.standard.set(tagsPrompt, forKey: Keys.tagsPrompt) }
    }

    var remoteChunkingEnabled: Bool {
        didSet { UserDefaults.standard.set(remoteChunkingEnabled, forKey: Keys.remoteChunkingEnabled) }
    }

    var remoteChunkMaxUploadMB: Int {
        didSet { UserDefaults.standard.set(remoteChunkMaxUploadMB, forKey: Keys.remoteChunkMaxUploadMB) }
    }

    var remoteChunkOverlapSeconds: Double {
        didSet { UserDefaults.standard.set(remoteChunkOverlapSeconds, forKey: Keys.remoteChunkOverlapSeconds) }
    }

    var remoteChunkRetryCount: Int {
        didSet { UserDefaults.standard.set(remoteChunkRetryCount, forKey: Keys.remoteChunkRetryCount) }
    }

    // MARK: - Meeting Profiles

    var profiles: [MeetingProfile] {
        didSet { saveProfiles(profiles) }
    }

    var activeProfileId: UUID {
        didSet { UserDefaults.standard.set(activeProfileId.uuidString, forKey: Keys.activeProfileId) }
    }

    // MARK: - Call Detection

    var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    var callDetectionEnabled: Bool {
        didSet { UserDefaults.standard.set(callDetectionEnabled, forKey: Keys.callDetectionEnabled) }
    }

    var autoRecordCalls: Bool {
        didSet { UserDefaults.standard.set(autoRecordCalls, forKey: Keys.autoRecordCalls) }
    }

    var disabledCallApps: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(disabledCallApps), forKey: Keys.disabledCallApps)
        }
    }

    // MARK: - Endpoints

    var transcriptionEndpoints: [Endpoint] {
        didSet { saveEndpoints(transcriptionEndpoints, forKey: Keys.transcriptionEndpoints) }
    }

    var aiEndpoints: [Endpoint] {
        didSet { saveEndpoints(aiEndpoints, forKey: Keys.aiEndpoints) }
    }

    var defaultTranscriptionEndpointId: UUID? {
        didSet {
            if let id = defaultTranscriptionEndpointId {
                UserDefaults.standard.set(id.uuidString, forKey: Keys.defaultTranscriptionEndpointId)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.defaultTranscriptionEndpointId)
            }
        }
    }

    var defaultAIEndpointId: UUID? {
        didSet {
            if let id = defaultAIEndpointId {
                UserDefaults.standard.set(id.uuidString, forKey: Keys.defaultAIEndpointId)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.defaultAIEndpointId)
            }
        }
    }

    // MARK: - Transient State

    var dismissedCallAppPIDs: Set<pid_t> = []

    // MARK: - Computed

    var defaultTranscriptionEndpoint: Endpoint? {
        guard let id = defaultTranscriptionEndpointId else {
            return transcriptionEndpoints.first
        }
        return transcriptionEndpoints.first { $0.id == id } ?? transcriptionEndpoints.first
    }

    var defaultAIEndpoint: Endpoint? {
        guard let id = defaultAIEndpointId else {
            return aiEndpoints.first
        }
        return aiEndpoints.first { $0.id == id } ?? aiEndpoints.first
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        self.recordingFolderURL = Self.loadBookmarkURL(key: Keys.recordingFolderBookmark)
            ?? Self.defaultRecordingFolder()
        self.transcriptionFolderURL = Self.loadBookmarkURL(key: Keys.transcriptionFolderBookmark)
            ?? Self.defaultTranscriptionFolder()
        self.obsidianVaultURL = Self.loadBookmarkURL(key: Keys.obsidianVaultBookmark)
        self.obsidianEnabled = defaults.object(forKey: Keys.obsidianEnabled) as? Bool ?? false
        self.obsidianDefaultFolderRelativePath = defaults.string(
            forKey: Keys.obsidianDefaultFolderRelativePath
        ) ?? ""
        self.integrations = Self.loadIntegrationSettings(forKey: Keys.integrationSettings)
        self.notionToken = KeychainHelper.get(for: .notion)
        self.evernoteToken = KeychainHelper.get(for: .evernote)
        self.googleKeepToken = KeychainHelper.get(for: .googleKeep)
        self.oneNoteToken = KeychainHelper.get(for: .oneNote)

        self.autoTranscribe = defaults.object(forKey: Keys.autoTranscribe) as? Bool ?? true
        self.autoSummary = defaults.object(forKey: Keys.autoSummary) as? Bool ?? true
        self.autoActionItems = defaults.object(forKey: Keys.autoActionItems) as? Bool ?? true
        self.autoTags = defaults.object(forKey: Keys.autoTags) as? Bool ?? true

        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)

        if let rawValue = defaults.string(forKey: Keys.aiEngine),
           let engine = AIEngine(rawValue: rawValue)
        {
            self.aiEngine = engine
        } else {
            let legacyBuiltIn = defaults.bool(forKey: Keys.useBuiltInAI)
            self.aiEngine = legacyBuiltIn ? .appleIntelligence : .remoteEndpoint
        }

        let outputLanguageMode = defaults.string(forKey: Keys.outputLanguageMode) ?? "matchInput"
        switch outputLanguageMode {
        case "english":
            self.outputLanguage = .english
        case "dutch":
            self.outputLanguage = .dutch
        case "custom":
            let code = (defaults.string(forKey: Keys.outputLanguageCustomCode) ?? "EN")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.outputLanguage = .custom(code.isEmpty ? "EN" : code)
        default:
            self.outputLanguage = .matchInput
        }

        self.audioSampleRate = defaults.object(forKey: Keys.audioSampleRate) as? Int ?? 16000
        self.audioBitRate = defaults.object(forKey: Keys.audioBitRate) as? Int ?? 128000
        self.audioInputDeviceUID = defaults.string(forKey: Keys.audioInputDeviceUID) ?? ""
        self.showDockIcon = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? false
        self.powerUserMode = defaults.object(forKey: Keys.powerUserMode) as? Bool ?? false
        self.obsidianIncludeTranscript = defaults.object(forKey: Keys.obsidianIncludeTranscript) as? Bool ?? false

        self.transcriptionLanguage = defaults.string(forKey: Keys.transcriptionLanguage) ?? ""
        self.whisperPrompt = defaults.string(forKey: Keys.whisperPrompt) ?? ""

        self.summaryPrompt = defaults.string(forKey: Keys.summaryPrompt) ?? Self.defaultSummaryPrompt
        self.actionItemsPrompt = defaults.string(forKey: Keys.actionItemsPrompt) ?? Self.defaultActionItemsPrompt
        self.tagsPrompt = defaults.string(forKey: Keys.tagsPrompt) ?? Self.defaultTagsPrompt
        self.remoteChunkingEnabled = defaults.object(forKey: Keys.remoteChunkingEnabled) as? Bool ?? true
        self.remoteChunkMaxUploadMB = max(1, defaults.object(forKey: Keys.remoteChunkMaxUploadMB) as? Int ?? 15)
        self.remoteChunkOverlapSeconds = max(
            0,
            defaults.object(forKey: Keys.remoteChunkOverlapSeconds) as? Double ?? 2.0
        )
        self.remoteChunkRetryCount = max(0, defaults.object(forKey: Keys.remoteChunkRetryCount) as? Int ?? 2)

        self.callDetectionEnabled = defaults.object(forKey: Keys.callDetectionEnabled) as? Bool ?? true
        self.autoRecordCalls = defaults.object(forKey: Keys.autoRecordCalls) as? Bool ?? false
        self.disabledCallApps = Set(defaults.stringArray(forKey: Keys.disabledCallApps) ?? [])

        self.transcriptionEndpoints = Self.loadEndpoints(forKey: Keys.transcriptionEndpoints)
        self.aiEndpoints = Self.loadEndpoints(forKey: Keys.aiEndpoints)

        if let idString = defaults.string(forKey: Keys.defaultTranscriptionEndpointId) {
            self.defaultTranscriptionEndpointId = UUID(uuidString: idString)
        } else {
            self.defaultTranscriptionEndpointId = nil
        }

        if let idString = defaults.string(forKey: Keys.defaultAIEndpointId) {
            self.defaultAIEndpointId = UUID(uuidString: idString)
        } else {
            self.defaultAIEndpointId = nil
        }

        if let rawValue = defaults.string(forKey: Keys.transcriptionEngine),
           let engine = TranscriptionEngine(rawValue: rawValue)
        {
            self.transcriptionEngine = engine
        } else {
            let legacyBuiltIn = defaults.bool(forKey: Keys.useBuiltInTranscription)
            self.transcriptionEngine = legacyBuiltIn ? .appleSpeech : .remoteEndpoint
        }

        var loadedProfiles = Self.loadProfiles(forKey: Keys.profiles)
        if loadedProfiles.isEmpty {
            loadedProfiles = Self.builtInProfiles()
        } else if !loadedProfiles.contains(where: { $0.preset == .default }) {
            loadedProfiles.insert(Self.defaultProfile(), at: 0)
        }

        let resolvedActiveProfileId: UUID
        if let rawID = defaults.string(forKey: Keys.activeProfileId),
           let parsed = UUID(uuidString: rawID),
           loadedProfiles.contains(where: { $0.id == parsed })
        {
            resolvedActiveProfileId = parsed
        } else if let defaultID = loadedProfiles.first(where: { $0.preset == .default })?.id {
            resolvedActiveProfileId = defaultID
        } else {
            resolvedActiveProfileId = loadedProfiles[0].id
        }

        self.profiles = loadedProfiles
        self.activeProfileId = resolvedActiveProfileId
    }
}
