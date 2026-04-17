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
        static let whisperModelName = "whisperModelName"
        static let whisperComputeUnits = "whisperComputeUnits"
        static let diarizationEnabled = "diarizationEnabled"
        static let parakeetModelVariant = "parakeetModelVariant"
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
        case parakeetLocal
        case remoteEndpoint

        var displayName: String {
            switch self {
            case .appleSpeech: "Apple Speech"
            case .localWhisper: "Local Whisper"
            case .parakeetLocal: "Parakeet (Local)"
            case .remoteEndpoint: "Remote Endpoint"
            }
        }
    }


    enum WhisperComputeUnits: String, CaseIterable, Codable, Hashable, Sendable {
        case cpuAndNeuralEngine
        case cpuAndGPU
        case all

        var displayName: String {
            switch self {
            case .cpuAndNeuralEngine: "Neural Engine"
            case .cpuAndGPU: "Metal GPU"
            case .all: "All (GPU + Neural Engine)"
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
            case .qwenLocal: "Gemma 4 E4B Local"
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

    /// WhisperKit model name to use for local transcription (e.g., "openai_whisper-small").
    var whisperModelName: String {
        didSet { UserDefaults.standard.set(whisperModelName, forKey: Keys.whisperModelName) }
    }

    /// Compute units for WhisperKit CoreML inference (Metal GPU / Neural Engine selection).
    /// Kept for backward compatibility but no longer used — WhisperKit's per-component defaults are used instead.
    var whisperComputeUnits: WhisperComputeUnits {
        didSet { UserDefaults.standard.set(whisperComputeUnits.rawValue, forKey: Keys.whisperComputeUnits) }
    }

    /// Enable SpeakerKit speaker diarization after transcription (identifies who said what).
    var diarizationEnabled: Bool {
        didSet { UserDefaults.standard.set(diarizationEnabled, forKey: Keys.diarizationEnabled) }
    }

    /// Parakeet CoreML model variant to use for local Parakeet transcription.
    var parakeetModelVariant: String {
        didSet { UserDefaults.standard.set(parakeetModelVariant, forKey: Keys.parakeetModelVariant) }
    }

    // MARK: - AI Prompts

    static let defaultSummaryPrompt = """
        You are an assistant that summarizes meeting transcriptions. \
        Write the summary in the same language as the transcription. \
        Structure: \
        1. **Overview** — 2-3 sentences capturing the meeting's purpose and main outcome. \
        2. **Discussion Points** — One paragraph per major topic, covering what was discussed, \
        key arguments or viewpoints raised, and any context needed to understand the discussion. \
        Include participant names when relevant. \
        3. **Decisions & Outcomes** — Bullet list of concrete decisions made and their rationale. \
        4. **Open Questions** — Any unresolved topics or questions that were left for follow-up. \
        Be detailed enough that someone who missed the meeting gets a clear, complete picture. \
        Do not omit topics even if they seem minor. \
        Do not add conversational filler or introductory text — start directly with the overview.
        """

    static let defaultActionItemsPrompt = """
        You are an assistant that extracts action items from meeting transcriptions. \
        Write in the same language as the transcription. \
        Extract ONLY concrete, committed action items — tasks someone explicitly agreed to do or was clearly assigned. \
        Do NOT include: vague suggestions ("we should look into...", "it would be nice to..."), \
        general discussion topics or ideas without a clear owner or commitment, \
        decisions (those belong in the summary), or duplicate items. \
        If the same task is mentioned multiple times, list it once. \
        Format each item as a single line starting with "- ", including: \
        the task itself (specific and actionable), owner name if mentioned, deadline or timeframe if mentioned. \
        Output ONLY the list. No introductory text, headers, or markdown code blocks. \
        If there are no concrete action items, output exactly: "- No action items identified"
        """

    static let defaultTagsPrompt = """
        You are an assistant that analyzes meeting transcriptions. \
        Respond in the same language as the transcription. \
        Output a JSON object with exactly two fields: \
        "tags" (array of 3-7 topic tags, lowercase, no spaces, use hyphens for multi-word tags \
        e.g. "project-management", no # prefix, no special characters except hyphens, \
        must be compatible with Obsidian) and \
        "sentiment" (one of: "positive", "neutral", "negative", "mixed" — \
        use "mixed" only when the meeting had clearly distinct positive and negative segments). \
        Output valid JSON only. No markdown code fences, no explanation.
        """

    static let teamMeetingWhisperPrompt =
        "Team standup, sprint, backlog, blocker, follow-up, ETA, Jira, PR, release, roadmap, architecture."

    static let teamMeetingSummaryPrompt = """
        Summarize this internal team meeting. Write in the same language as the transcription. \
        Structure: \
        1. **Overview** — 1-2 sentences on the meeting's purpose. \
        2. **Progress Updates** — What each person or team reported, including status and blockers. \
        3. **Decisions** — Bullet list of what was decided and why. \
        4. **Next Steps** — What happens next, including owners and timelines if mentioned. \
        Keep tone informal and practical. Be detailed enough that absent team members are fully caught up.
        """

    static let teamMeetingActionItemsPrompt = """
        Extract action items from this team meeting. Write in the same language as the transcription. \
        Only include tasks someone explicitly committed to or was assigned. \
        Exclude vague suggestions, discussion topics, and decisions without a clear task. \
        Deduplicate — list each task once even if mentioned multiple times. \
        Format: bullet lines beginning with "- ", including owner and due date if mentioned. Keep wording short. \
        If there are no concrete action items, output exactly: "- No action items identified"
        """

    static let teamMeetingTagsPrompt = """
        Respond in the same language as the transcription. \
        Return valid JSON only: {"tags": [...], "sentiment": "..."}. \
        Tags: 3-7 tags reflecting internal collaboration topics (planning, delivery, blockers, risks, dependencies). \
        Lowercase, no spaces (use hyphens for multi-word tags e.g. "sprint-planning"), no # prefix, Obsidian-compatible. \
        Sentiment: one of "positive", "neutral", "negative", "mixed". \
        No markdown code fences, no explanation.
        """

    static let salesMeetingWhisperPrompt =
        "Customer, contract, pricing, procurement, renewal, objections, competitor, timeline, stakeholder, action item, follow-up."

    static let salesMeetingSummaryPrompt = """
        Summarize this sales meeting. Write in the same language as the transcription. \
        Structure: \
        1. **Overview** — 1-2 sentences on who attended and the meeting's purpose. \
        2. **Customer Requirements & Concerns** — What the customer needs, their pain points, and any objections raised. \
        3. **Commercial Discussion** — Pricing, terms, timelines, and any commitments made by either side. \
        4. **Decisions & Agreements** — Bullet list of what was agreed upon. \
        5. **Risks & Open Items** — Unresolved concerns, competitor mentions, or blockers to closing. \
        6. **Next Steps** — Agreed follow-up actions with owners and dates if mentioned. \
        Keep tone professional and factually precise. Prioritize accuracy over brevity — \
        this summary may be shared with stakeholders who were not present.
        """

    static let salesMeetingActionItemsPrompt = """
        Extract action items for sales follow-up. Write in the same language as the transcription. \
        Only include tasks that were explicitly committed to or assigned — not vague intentions or discussion points. \
        Deduplicate — list each task once even if mentioned multiple times. \
        Format: bullet lines beginning with "- ", including owner, expected outcome, and date when available. \
        Be exact and unambiguous. \
        If there are no concrete action items, output exactly: "- No action items identified"
        """

    static let salesMeetingTagsPrompt = """
        Respond in the same language as the transcription. \
        Return valid JSON only: {"tags": [...], "sentiment": "..."}. \
        Tags: 3-7 tags focusing on deal stage, customer needs, objections, budget, timeline, decision process. \
        Lowercase, no spaces (use hyphens for multi-word tags e.g. "deal-negotiation"), no # prefix, Obsidian-compatible. \
        Sentiment: one of "positive", "neutral", "negative", "mixed". \
        No markdown code fences, no explanation.
        """

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
        self.whisperModelName = {
            // New key takes priority
            if let name = defaults.string(forKey: Keys.whisperModelName), !name.isEmpty {
                return name
            }
            // Migrate from old enum-based key
            switch defaults.string(forKey: "whisperModelSize") ?? "" {
            case "small":  return "openai_whisper-small"
            case "medium": return "openai_whisper-medium"
            default:       return "openai_whisper-small"
            }
        }()
        self.whisperComputeUnits = WhisperComputeUnits(rawValue: defaults.string(forKey: Keys.whisperComputeUnits) ?? "") ?? .all
        self.diarizationEnabled = defaults.object(forKey: Keys.diarizationEnabled) as? Bool ?? false
        self.parakeetModelVariant = defaults.string(forKey: Keys.parakeetModelVariant) ?? "v3"

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
