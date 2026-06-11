import Foundation
import SwiftUI
import CoreML
import dBriefWire

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
        static let aiProcessingEnabled = "aiProcessingEnabled"
        static let callDetectionEnabled = "callDetectionEnabled"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let autoRecordCalls = "autoRecordCalls"
        static let disabledCallApps = "disabledCallApps"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let useBuiltInTranscription = "useBuiltInTranscription"
        static let transcriptionEngine = "transcriptionEngine"
        static let useBuiltInAI = "useBuiltInAI"
        static let aiEngine = "aiEngine"
        static let chatFallbackEngine = "chatFallbackEngine"
        static let localCLIConfig = "localCLIConfig"
        static let didMigrateLocalCLITimeout = "didMigrateLocalCLITimeout"
        static let outputLanguageMode = "outputLanguageMode"
        static let outputLanguageCustomCode = "outputLanguageCustomCode"
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
        static let acousticEchoCancellation = "acousticEchoCancellation"
        static let prewarmWhisperOnLaunch = "prewarmWhisperOnLaunch"
        static let autoProcessAfterStop = "autoProcessAfterStop"
        static let lifetimeTranscribedSeconds = "lifetimeTranscribedSeconds"
        static let parakeetModelVariant = "parakeetModelVariant"
        static let calendarSource = "calendarSource"
        static let recordHotkey = "recordHotkey"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let lastUpdateCheckTime = "lastUpdateCheckTime"
        static let lastNotifiedUpdateVersion = "lastNotifiedUpdateVersion"
        static let autoDeleteRecordingsEnabled = "autoDeleteRecordingsEnabled"
        static let autoDeleteRecordingsDays = "autoDeleteRecordingsDays"
        static let autoDeleteTranscriptsEnabled = "autoDeleteTranscriptsEnabled"
        static let autoDeleteTranscriptsDays = "autoDeleteTranscriptsDays"
    }

    // MARK: - Recording

    var recordingFolderURL: URL {
        didSet { saveBookmark(for: recordingFolderURL, key: Keys.recordingFolderBookmark) }
    }

    var transcriptionFolderURL: URL {
        didSet { saveBookmark(for: transcriptionFolderURL, key: Keys.transcriptionFolderBookmark) }
    }

    // MARK: - Privacy / Retention

    /// Automatically delete audio recordings older than `autoDeleteRecordingsDays`.
    /// Transcripts and notes are left in place.
    var autoDeleteRecordingsEnabled: Bool {
        didSet { UserDefaults.standard.set(autoDeleteRecordingsEnabled, forKey: Keys.autoDeleteRecordingsEnabled) }
    }

    /// Age (in days) after which recordings are auto-deleted.
    var autoDeleteRecordingsDays: Int {
        didSet { UserDefaults.standard.set(autoDeleteRecordingsDays, forKey: Keys.autoDeleteRecordingsDays) }
    }

    /// Automatically delete transcript / insights / Markdown files older than
    /// `autoDeleteTranscriptsDays`. Audio recordings are left in place.
    var autoDeleteTranscriptsEnabled: Bool {
        didSet { UserDefaults.standard.set(autoDeleteTranscriptsEnabled, forKey: Keys.autoDeleteTranscriptsEnabled) }
    }

    /// Age (in days) after which transcripts are auto-deleted.
    var autoDeleteTranscriptsDays: Int {
        didSet { UserDefaults.standard.set(autoDeleteTranscriptsDays, forKey: Keys.autoDeleteTranscriptsDays) }
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

    var aiProcessingEnabled: Bool {
        didSet { UserDefaults.standard.set(aiProcessingEnabled, forKey: Keys.aiProcessingEnabled) }
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

        /// One-line plain-language summary, shown under the picker in onboarding
        /// and Settings to help users choose.
        var shortDescription: String {
            switch self {
            case .appleSpeech: "Built in, no download. Uses Apple's latest on-device model on macOS 26; older systems use the classic recognizer."
            case .localWhisper: "On-device Whisper. Best accuracy, multilingual. Downloads a model once."
            case .parakeetLocal: "On-device, great for clear English speech. No speaker labels."
            case .remoteEndpoint: "Send audio to your own Whisper server or API."
            }
        }

        /// The engine we steer new users toward — private, on-device, and accurate.
        static let recommended: TranscriptionEngine = .localWhisper
        var isRecommended: Bool { self == Self.recommended }
    }


    typealias WhisperComputeUnits = dBriefWire.WhisperComputeUnits

    enum AIEngine: String, CaseIterable, Codable, Hashable, Sendable {
        case appleIntelligence
        case qwenLocal
        case remoteEndpoint
        case localCLI

        var displayName: String {
            switch self {
            case .appleIntelligence: "Apple Intelligence"
            case .qwenLocal: "Gemma 4 E4B Local"
            case .remoteEndpoint: "Remote Endpoint"
            case .localCLI: "Local CLI"
            }
        }

        /// One-line plain-language summary, shown under the picker in onboarding
        /// and Settings to help users choose.
        var shortDescription: String {
            switch self {
            case .appleIntelligence: "On-device and private. Requires macOS 26 on Apple Silicon."
            case .qwenLocal: "On-device Gemma model. Private, downloads once."
            case .remoteEndpoint: "Use an OpenAI-compatible LLM endpoint (e.g. your own server)."
            case .localCLI: "Run your own command (claude, ollama, llm…)."
            }
        }

        /// Whether this is the suggested zero-config choice for the current Mac.
        var isRecommended: Bool { self == Self.defaultOnDeviceFallback }

        /// A sensible zero-config on-device engine to fall back to (used for the
        /// transcript chat window when the active engine is `.localCLI`, which
        /// can't stream). Prefers Apple Intelligence when available, otherwise the
        /// local Gemma model — both run on-device with no remote endpoint to set up.
        static var defaultOnDeviceFallback: AIEngine {
            #if canImport(FoundationModels)
            if #available(macOS 26, *), LocalAIService.isAvailable {
                return .appleIntelligence
            }
            #endif
            return .qwenLocal
        }
    }

    typealias OutputLanguage = dBriefWire.OutputLanguage

    /// Preferred transcription engine (Apple Speech, Local Whisper, or remote endpoint).
    var transcriptionEngine: TranscriptionEngine {
        didSet { UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) }
    }

    /// Preferred AI engine (Apple Intelligence, local Qwen model, remote endpoint, or local CLI).
    var aiEngine: AIEngine {
        didSet { UserDefaults.standard.set(aiEngine.rawValue, forKey: Keys.aiEngine) }
    }

    /// Engine used for the transcript chat window when the active AI engine is `.localCLI`
    /// (a one-shot CLI can't stream). Never `.localCLI` itself — coerced on assignment.
    var chatFallbackEngine: AIEngine {
        didSet {
            if chatFallbackEngine == .localCLI { chatFallbackEngine = AIEngine.defaultOnDeviceFallback; return }
            UserDefaults.standard.set(chatFallbackEngine.rawValue, forKey: Keys.chatFallbackEngine)
        }
    }

    /// Configuration for the Local CLI AI engine (command template + timeout).
    var localCLIConfig: LocalCLIConfig {
        didSet { saveLocalCLIConfig(localCLIConfig) }
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

    /// Automatically check GitHub for app updates on launch (throttled to once/24h)
    var autoCheckUpdates: Bool {
        didSet { UserDefaults.standard.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) }
    }

    /// Last time the app checked for updates; persisted as seconds since 1970
    var lastUpdateCheckTime: Date? {
        didSet {
            if let date = lastUpdateCheckTime {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Keys.lastUpdateCheckTime)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.lastUpdateCheckTime)
            }
        }
    }

    /// The latest version the user was already shown an "Update available" popup for.
    /// Used to surface the popup only once per new release (the menu-bar badge stays).
    var lastNotifiedUpdateVersion: String? {
        didSet {
            if let version = lastNotifiedUpdateVersion {
                UserDefaults.standard.set(version, forKey: Keys.lastNotifiedUpdateVersion)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.lastNotifiedUpdateVersion)
            }
        }
    }

    /// Global keyboard shortcut for toggling recording (user-configurable in Settings → General)
    var recordHotkey: RecordHotkey {
        didSet {
            if let data = try? JSONEncoder().encode(recordHotkey) {
                UserDefaults.standard.set(data, forKey: Keys.recordHotkey)
            }
        }
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

    /// Enable Acoustic Echo Cancellation on the microphone input.
    var acousticEchoCancellation: Bool {
        didSet { UserDefaults.standard.set(acousticEchoCancellation, forKey: Keys.acousticEchoCancellation) }
    }

    /// Warm the local Whisper model ~3 s after launch and on wake, so the first
    /// transcription starts instantly. Off by default — it holds the model in
    /// memory while idle, which competes with a local analysis LLM.
    var prewarmWhisperOnLaunch: Bool {
        didSet { UserDefaults.standard.set(prewarmWhisperOnLaunch, forKey: Keys.prewarmWhisperOnLaunch) }
    }

    /// Skip the post-recording options sheet and immediately start processing
    /// (transcription + AI) with the effective default options when a recording
    /// stops. Off by default. While processing runs the Mac must stay awake —
    /// see the warning in Settings → General.
    var autoProcessAfterStop: Bool {
        didSet { UserDefaults.standard.set(autoProcessAfterStop, forKey: Keys.autoProcessAfterStop) }
    }

    /// Lifetime total of audio seconds dBrief has transcribed to text. A
    /// monotonically-increasing odometer that survives "Clear benchmark stats".
    var lifetimeTranscribedSeconds: Double {
        didSet { UserDefaults.standard.set(lifetimeTranscribedSeconds, forKey: Keys.lifetimeTranscribedSeconds) }
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

    var calendarSource: CalendarSource {
        didSet { UserDefaults.standard.set(calendarSource.rawValue, forKey: Keys.calendarSource) }
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
        self.autoDeleteRecordingsEnabled = defaults.object(forKey: Keys.autoDeleteRecordingsEnabled) as? Bool ?? false
        self.autoDeleteRecordingsDays = max(1, defaults.object(forKey: Keys.autoDeleteRecordingsDays) as? Int ?? 30)
        self.autoDeleteTranscriptsEnabled = defaults.object(forKey: Keys.autoDeleteTranscriptsEnabled) as? Bool ?? false
        self.autoDeleteTranscriptsDays = max(1, defaults.object(forKey: Keys.autoDeleteTranscriptsDays) as? Int ?? 30)

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
        self.aiProcessingEnabled = defaults.object(forKey: Keys.aiProcessingEnabled) as? Bool ?? true

        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)

        if let rawValue = defaults.string(forKey: Keys.aiEngine),
           let engine = AIEngine(rawValue: rawValue)
        {
            self.aiEngine = engine
        } else {
            let legacyBuiltIn = defaults.bool(forKey: Keys.useBuiltInAI)
            // Fresh installs default to a private, on-device engine that works
            // without configuring a remote endpoint.
            self.aiEngine = legacyBuiltIn ? .appleIntelligence : .defaultOnDeviceFallback
        }

        if let rawValue = defaults.string(forKey: Keys.chatFallbackEngine),
           let engine = AIEngine(rawValue: rawValue), engine != .localCLI
        {
            self.chatFallbackEngine = engine
        } else {
            self.chatFallbackEngine = AIEngine.defaultOnDeviceFallback
        }

        self.localCLIConfig = AppSettings.loadLocalCLIConfig(forKey: Keys.localCLIConfig)

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

        self.audioInputDeviceUID = defaults.string(forKey: Keys.audioInputDeviceUID) ?? ""
        self.showDockIcon = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? false
        self.powerUserMode = defaults.object(forKey: Keys.powerUserMode) as? Bool ?? false
        self.autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
        if let interval = defaults.object(forKey: Keys.lastUpdateCheckTime) as? TimeInterval {
            self.lastUpdateCheckTime = Date(timeIntervalSince1970: interval)
        } else {
            self.lastUpdateCheckTime = nil
        }
        self.lastNotifiedUpdateVersion = defaults.string(forKey: Keys.lastNotifiedUpdateVersion)
        self.recordHotkey = {
            if let data = defaults.data(forKey: Keys.recordHotkey),
               let hotkey = try? JSONDecoder().decode(RecordHotkey.self, from: data)
            {
                return hotkey
            }
            return .default
        }()
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
            default:       return WhisperModelInfo.recommendedModelID
            }
        }()
        self.whisperComputeUnits = WhisperComputeUnits(rawValue: defaults.string(forKey: Keys.whisperComputeUnits) ?? "") ?? .all
        self.diarizationEnabled = defaults.object(forKey: Keys.diarizationEnabled) as? Bool ?? false
        self.acousticEchoCancellation = defaults.object(forKey: Keys.acousticEchoCancellation) as? Bool ?? true
        self.prewarmWhisperOnLaunch = defaults.object(forKey: Keys.prewarmWhisperOnLaunch) as? Bool ?? false
        self.autoProcessAfterStop = defaults.object(forKey: Keys.autoProcessAfterStop) as? Bool ?? false
        self.lifetimeTranscribedSeconds = defaults.object(forKey: Keys.lifetimeTranscribedSeconds) as? Double ?? 0
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
        if let raw = defaults.string(forKey: Keys.calendarSource),
           let source = CalendarSource(rawValue: raw) {
            self.calendarSource = source
        } else if let legacy = defaults.object(forKey: "calendarIntegrationEnabled") as? Bool {
            self.calendarSource = legacy ? .iCal : .disabled
        } else {
            self.calendarSource = .iCal
        }
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
            // Fresh installs default to on-device Whisper rather than an
            // unconfigured remote endpoint.
            self.transcriptionEngine = legacyBuiltIn ? .appleSpeech : .recommended
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

extension OutputLanguage {
    /// Stable storage discriminator for the language mode, used by
    /// `AppSettings` UserDefaults persistence.
    var modeStorageValue: String {
        switch self {
        case .matchInput: "matchInput"
        case .english: "english"
        case .dutch: "dutch"
        case .custom: "custom"
        }
    }
}
