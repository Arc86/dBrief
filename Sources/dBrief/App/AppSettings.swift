import Foundation
import SwiftUI
import CoreML
import dBriefWire

@MainActor
@Observable
final class AppSettings {
    static let calendarMatchWindowOptions = [0, 5, 10, 15, 30, 60]

    /// Maps stale or externally-written preferences to a value rendered by the Settings menu.
    static func normalizedCalendarMatchWindowMinutes(_ value: Int) -> Int {
        guard let lower = calendarMatchWindowOptions.first,
              let upper = calendarMatchWindowOptions.last else { return 15 }
        let bounded = min(max(value, lower), upper)
        return calendarMatchWindowOptions.min {
            abs($0 - bounded) < abs($1 - bounded)
        } ?? 15
    }

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
        static let autoDismissCallPromptSeconds = "autoDismissCallPromptSeconds"
        static let disabledCallApps = "disabledCallApps"
        static let stopRecordingOnCallEnd = "stopRecordingOnCallEnd"
        static let callEndScope = "callEndScope"
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
        static let customVocabulary = "customVocabulary"
        static let removeFillerWords = "removeFillerWords"
        static let watchedFoldersEnabled = "watchedFoldersEnabled"
        static let watchedFolders = "watchedFolders"
        static let watchedFolderNotifyOnDetect = "watchedFolderNotifyOnDetect"
        static let removeIgnoredSegments = "removeIgnoredSegments"
        static let customIgnoredSegments = "customIgnoredSegments"
        static let transcriptionEndpoints = "transcriptionEndpoints"
        static let aiEndpoints = "aiEndpoints"
        static let defaultTranscriptionEndpointId = "defaultTranscriptionEndpointId"
        static let defaultAIEndpointId = "defaultAIEndpointId"
        static let dismissedCallAppPIDs = "dismissedCallAppPIDs"
        static let summaryPrompt = "summaryPrompt"
        static let actionItemsPrompt = "actionItemsPrompt"
        static let tagsPrompt = "tagsPrompt"
        static let spokenSummaryPrompt = "spokenSummaryPrompt"
        static let ttsDeliveryInstruction = "ttsDeliveryInstruction"
        static let ttsModelSize = "ttsModelSize"
        static let ttsVoice = "ttsVoice"
        static let ttsLanguage = "ttsLanguage"
        static let ttsEngine = "ttsEngine"
        static let ttsKokoroVoice = "ttsKokoroVoice"
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
        static let speakerIdMode = "speakerIdMode"
        static let liveTranscriptionEnabled = "liveTranscriptionEnabled"
        static let acousticEchoCancellation = "acousticEchoCancellation"
        static let prewarmWhisperOnLaunch = "prewarmWhisperOnLaunch"
        static let showMiniRecordingView = "showMiniRecordingView"
        static let showMenuBarRecordingDuration = "showMenuBarRecordingDuration"
        static let reduceNeon = "reduceNeon"
        static let lifetimeTranscribedSeconds = "lifetimeTranscribedSeconds"
        static let parakeetModelVariant = "parakeetModelVariant"
        static let calendarSource = "calendarSource"
        static let calendarMatchWindowMinutes = "calendarMatchWindowMinutes"
        static let showAllMeetingsFromRecordingDay = "showAllMeetingsFromRecordingDay"
        static let selectedICalCalendarIDs = "selectedICalCalendarIDs"
        static let recordHotkey = "recordHotkey"
        static let autoDeleteRecordingsEnabled = "autoDeleteRecordingsEnabled"
        static let autoDeleteRecordingsDays = "autoDeleteRecordingsDays"
        static let autoDeleteTranscriptsEnabled = "autoDeleteTranscriptsEnabled"
        static let autoDeleteTranscriptsDays = "autoDeleteTranscriptsDays"
        static let lastRetentionCleanupDate = "lastRetentionCleanupDate"
        static let lastRetentionCleanupSummary = "lastRetentionCleanupSummary"
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

    /// Most recent automatic or user-triggered retention sweep. Persisted so the
    /// scheduler can enforce a daily cadence across launches and Settings can show
    /// users when their privacy policy last ran.
    var lastRetentionCleanupDate: Date? {
        didSet {
            if let lastRetentionCleanupDate {
                UserDefaults.standard.set(lastRetentionCleanupDate, forKey: Keys.lastRetentionCleanupDate)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.lastRetentionCleanupDate)
            }
        }
    }

    var lastRetentionCleanupSummary: String {
        didSet { UserDefaults.standard.set(lastRetentionCleanupSummary, forKey: Keys.lastRetentionCleanupSummary) }
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
        didSet { saveKeychainSecret(notionToken, for: .notion) }
    }

    var evernoteToken: String {
        didSet { saveKeychainSecret(evernoteToken, for: .evernote) }
    }

    var googleKeepToken: String {
        didSet { saveKeychainSecret(googleKeepToken, for: .googleKeep) }
    }

    var oneNoteToken: String {
        didSet { saveKeychainSecret(oneNoteToken, for: .oneNote) }
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

    /// How diarized speakers get their identities.
    enum SpeakerIdMode: String, CaseIterable, Codable, Hashable, Sendable {
        case optimistic    // auto-label confident matches, run straight through (default)
        case confirmFirst  // hold before AI; review speaker IDs first

        var displayName: String {
            switch self {
            case .optimistic: "Optimistic"
            case .confirmFirst: "Confirm first"
            }
        }

        var shortDescription: String {
            switch self {
            case .optimistic: "Auto-label matched voices and keep processing."
            case .confirmFirst: "Pause to review speaker names before analysis."
            }
        }
    }

    /// What dBrief does when the call app that started a recording ends its meeting.
    /// Best-effort: on macOS 14.2+ it fires when the call app stops using the mic
    /// (even while the app stays running); on older macOS only when the app quits.
    enum CallEndAction: String, CaseIterable, Codable, Hashable, Sendable {
        case off        // never react to a call ending
        case prompt     // show a "call ended — stop recording?" prompt (default)
        case autoStop   // stop the recording automatically

        var displayName: String {
            switch self {
            case .off: "Do nothing"
            case .prompt: "Ask me"
            case .autoStop: "Stop automatically"
            }
        }
    }

    /// Which recordings the call-end action applies to.
    enum CallEndScope: String, CaseIterable, Codable, Hashable, Sendable {
        case callInitiatedOnly   // only recordings dBrief started for a call (default)
        case anyActiveRecording  // any active recording when a known call ends

        var displayName: String {
            switch self {
            case .callInitiatedOnly: "Only recordings started for a call"
            case .anyActiveRecording: "Any active recording"
            }
        }
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

    /// Custom vocabulary list for spell-correction and AI analysis context. Helps with proper nouns, acronyms, etc.
    var customVocabulary: [String] {
        didSet { UserDefaults.standard.set(customVocabulary, forKey: Keys.customVocabulary) }
    }

    /// When enabled, filler words (um, uh, …) are stripped from transcripts after
    /// transcription. Off by default — meeting records often want verbatim text.
    /// Hallucination/markup cleanup runs regardless of this toggle.
    var removeFillerWords: Bool {
        didSet { UserDefaults.standard.set(removeFillerWords, forKey: Keys.removeFillerWords) }
    }

    /// Master switch for the watched-folders drop-in transcription queue. Off by default.
    var watchedFoldersEnabled: Bool {
        didSet { UserDefaults.standard.set(watchedFoldersEnabled, forKey: Keys.watchedFoldersEnabled) }
    }

    /// Folders monitored for dropped-in audio files. New files are auto-transcribed using
    /// the global auto-processing preferences. Persisted as JSON (each holds a bookmark).
    var watchedFolders: [WatchedFolder] {
        didSet { saveWatchedFolders(watchedFolders) }
    }

    /// Post a notification when a new file is detected in a watched folder (default on).
    /// Completion notifications fire regardless via the normal processing pipeline.
    var watchedFolderNotifyOnDetect: Bool {
        didSet { UserDefaults.standard.set(watchedFolderNotifyOnDetect, forKey: Keys.watchedFolderNotifyOnDetect) }
    }

    /// When enabled (default), segments whose entire text matches a built-in or custom
    /// ignored phrase (e.g. "Thank you for watching", "♪") are dropped from the transcript
    /// before AI analysis, export, and integrations. Targets Whisper silence-hallucinations.
    var removeIgnoredSegments: Bool {
        didSet { UserDefaults.standard.set(removeIgnoredSegments, forKey: Keys.removeIgnoredSegments) }
    }

    /// User-added ignored phrases, layered on top of `TranscriptCleanup.defaultIgnoredSegments`.
    /// "Reset to defaults" in Settings clears this list.
    var customIgnoredSegments: [String] {
        didSet { UserDefaults.standard.set(customIgnoredSegments, forKey: Keys.customIgnoredSegments) }
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

    /// Optimistic (auto-label matched voices) vs. confirm-first (pause to review
    /// speaker identities before AI analysis). Only meaningful when diarizing.
    var speakerIdMode: SpeakerIdMode {
        didSet { UserDefaults.standard.set(speakerIdMode.rawValue, forKey: Keys.speakerIdMode) }
    }

    /// Enable real-time transcription (and live chat) during recording using Apple's
    /// in-process Speech framework. A preview only — the authoritative transcript is
    /// still produced post-recording.
    var liveTranscriptionEnabled: Bool {
        didSet { UserDefaults.standard.set(liveTranscriptionEnabled, forKey: Keys.liveTranscriptionEnabled) }
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

    /// Show the floating Mini Recording view (`FloatingMiniPlayer`) during recording.
    /// On by default.
    var showMiniRecordingView: Bool {
        didSet { UserDefaults.standard.set(showMiniRecordingView, forKey: Keys.showMiniRecordingView) }
    }

    /// Show the elapsed recording duration in the menu bar label while recording.
    /// On by default; when off, only the red record dot is shown.
    var showMenuBarRecordingDuration: Bool {
        didSet { UserDefaults.standard.set(showMenuBarRecordingDuration, forKey: Keys.showMenuBarRecordingDuration) }
    }

    /// Calm-appearance opt-in: swap the neon brand styling (gradient CTAs, glow
    /// halos, the neon-on-black transcript backdrop) for plain colors — a solid
    /// red record button, flat dark surfaces, no glow. Off by default so the
    /// signature brand look is preserved unless the user opts in.
    var reduceNeon: Bool {
        didSet { UserDefaults.standard.set(reduceNeon, forKey: Keys.reduceNeon) }
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

    static let defaultSpokenSummaryPrompt = """
        You are an assistant that turns a meeting's written summary and action items \
        into a short, natural-sounding spoken briefing to be read aloud by a \
        text-to-speech voice. \
        Always write the briefing in English, regardless of the language of the input. \
        Produce flowing spoken prose only — no headings, bullet points, markdown, \
        emoji, or list markers. \
        Open with one sentence framing what the meeting was about, then narrate the \
        key points and decisions conversationally, and finish by mentioning the most \
        important action items and who owns them. \
        Keep it concise (roughly 150-220 words), use complete sentences, and spell out \
        abbreviations where it helps listening. \
        Do not add meta commentary like "here is your summary" — start directly with \
        the briefing.
        """

    /// Default calm-delivery style instruction for the Spoken Summary TTS voice.
    /// Followed only by the 1.7B model.
    static let defaultTTSDeliveryInstruction =
        "Narrate in a calm, measured, professional tone. Speak at a relaxed, "
        + "unhurried pace and pause briefly between sentences. Avoid sounding "
        + "overly energetic or excited."

    static let teamMeetingVocabulary: [String] = [
        "Team standup", "sprint", "backlog", "blocker", "follow-up",
        "ETA", "Jira", "PR", "release", "roadmap", "architecture"
    ]

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

    static let salesMeetingVocabulary: [String] = [
        "Customer", "contract", "pricing", "procurement", "renewal",
        "objections", "competitor", "timeline", "stakeholder", "action item", "follow-up"
    ]

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

    /// Prompt for the second AI pass that rewrites insights into a spoken script
    /// for the Spoken Summary feature. User-editable in Settings → AI Analysis.
    var spokenSummaryPrompt: String {
        didSet { UserDefaults.standard.set(spokenSummaryPrompt, forKey: Keys.spokenSummaryPrompt) }
    }

    /// Style/delivery instruction fed to the Spoken Summary TTS voice. Only the
    /// 1.7B model follows it (the 0.6B variant ignores it). User-editable in
    /// Settings → AI Analysis; an empty value sends no instruction.
    var ttsDeliveryInstruction: String {
        didSet { UserDefaults.standard.set(ttsDeliveryInstruction, forKey: Keys.ttsDeliveryInstruction) }
    }

    /// Qwen3-TTS model size used for spoken-summary synthesis. 1.7B is the most
    /// natural (and the only one that follows `ttsDeliveryInstruction`); 0.6B is
    /// lighter for 16 GB Macs. Settings → AI Analysis.
    var ttsModelSize: TTSModelSize {
        didSet { UserDefaults.standard.set(ttsModelSize.rawValue, forKey: Keys.ttsModelSize) }
    }

    /// Qwen3-TTS speaker voice used for spoken-summary synthesis. Settings → AI Analysis.
    var ttsVoice: TTSVoice {
        didSet { UserDefaults.standard.set(ttsVoice.rawValue, forKey: Keys.ttsVoice) }
    }

    /// Qwen3-TTS output language used for spoken-summary synthesis. Settings → AI Analysis.
    var ttsLanguage: TTSLanguage {
        didSet { UserDefaults.standard.set(ttsLanguage.rawValue, forKey: Keys.ttsLanguage) }
    }

    /// Which on-device TTS engine synthesizes spoken summaries. Default Kokoro
    /// (fast, ANE-resident); Qwen3 is the broader-multilingual alternative.
    /// Settings → AI Analysis.
    var ttsEngine: TTSEngine {
        didSet { UserDefaults.standard.set(ttsEngine.rawValue, forKey: Keys.ttsEngine) }
    }

    /// Kokoro (FluidAudio) voice used when `ttsEngine == .kokoro`. Settings → AI Analysis.
    var ttsKokoroVoice: KokoroVoice {
        didSet { UserDefaults.standard.set(ttsKokoroVoice.rawValue, forKey: Keys.ttsKokoroVoice) }
    }

    /// Resolved parameters for a `synthesizeSpeech` call, branching on the selected
    /// TTS engine. Kokoro derives language from its voice id and has no style
    /// instruction or model-size control, so those are `nil` for it.
    var ttsSynthesisParams: (engine: String, voice: String?, language: String?, instruction: String?, model: String?) {
        switch ttsEngine {
        case .kokoro:
            return (ttsEngine.rawValue, ttsKokoroVoice.rawValue, nil, nil, nil)
        case .qwen3:
            return (ttsEngine.rawValue, ttsVoice.rawValue, ttsLanguage.rawValue, ttsDeliveryInstruction, ttsModelSize.rawValue)
        }
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

    /// Maximum difference between an event's start and the recording start when the two do
    /// not overlap. `0` restricts automatic matching to overlapping events. Values come from
    /// the Settings preset menu and are normalized on load for forward/backward compatibility.
    var calendarMatchWindowMinutes: Int {
        didSet { UserDefaults.standard.set(calendarMatchWindowMinutes, forKey: Keys.calendarMatchWindowMinutes) }
    }

    /// Expands the post-recording Meeting picker with every event overlapping the local
    /// calendar day on which the recording began. It never broadens automatic matching.
    var showAllMeetingsFromRecordingDay: Bool {
        didSet {
            UserDefaults.standard.set(
                showAllMeetingsFromRecordingDay,
                forKey: Keys.showAllMeetingsFromRecordingDay
            )
        }
    }

    /// EventKit calendars allowed to contribute meeting context. `nil` means all current and
    /// future calendars; an empty set deliberately means none. Keeping those states distinct
    /// prevents an explicit filter from ever broadening back to all calendars unexpectedly.
    var selectedICalCalendarIDs: Set<String>? {
        didSet {
            if let selectedICalCalendarIDs {
                UserDefaults.standard.set(
                    selectedICalCalendarIDs.sorted(),
                    forKey: Keys.selectedICalCalendarIDs
                )
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.selectedICalCalendarIDs)
            }
        }
    }

    var autoRecordCalls: Bool {
        didSet { UserDefaults.standard.set(autoRecordCalls, forKey: Keys.autoRecordCalls) }
    }

    /// Auto-dismiss the "call detected" prompt after this many seconds. `0` = never (the
    /// prompt stays until the user acts). Cancelled if the user interacts with the prompt.
    var autoDismissCallPromptSeconds: Int {
        didSet { UserDefaults.standard.set(autoDismissCallPromptSeconds, forKey: Keys.autoDismissCallPromptSeconds) }
    }

    var disabledCallApps: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(disabledCallApps), forKey: Keys.disabledCallApps)
        }
    }

    /// What to do when the call app that started a recording ends its meeting.
    var stopRecordingOnCallEnd: CallEndAction {
        didSet { UserDefaults.standard.set(stopRecordingOnCallEnd.rawValue, forKey: Keys.stopRecordingOnCallEnd) }
    }

    /// Which recordings `stopRecordingOnCallEnd` applies to.
    var callEndScope: CallEndScope {
        didSet { UserDefaults.standard.set(callEndScope.rawValue, forKey: Keys.callEndScope) }
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
        self.lastRetentionCleanupDate = defaults.object(forKey: Keys.lastRetentionCleanupDate) as? Date
        self.lastRetentionCleanupSummary = defaults.string(forKey: Keys.lastRetentionCleanupSummary) ?? ""

        self.obsidianVaultURL = Self.loadBookmarkURL(key: Keys.obsidianVaultBookmark)
        self.obsidianEnabled = defaults.object(forKey: Keys.obsidianEnabled) as? Bool ?? false
        self.obsidianDefaultFolderRelativePath = defaults.string(
            forKey: Keys.obsidianDefaultFolderRelativePath
        ) ?? ""
        self.integrations = Self.loadIntegrationSettings(forKey: Keys.integrationSettings)
        self.notionToken = Self.loadKeychainSecret(for: .notion)
        self.evernoteToken = Self.loadKeychainSecret(for: .evernote)
        self.googleKeepToken = Self.loadKeychainSecret(for: .googleKeep)
        self.oneNoteToken = Self.loadKeychainSecret(for: .oneNote)

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
        // Migration: if customVocabulary absent but legacy whisperPrompt exists, parse and migrate
        if let existing = defaults.stringArray(forKey: Keys.customVocabulary) {
            self.customVocabulary = existing
        } else if let legacy = defaults.string(forKey: "whisperPrompt"), !legacy.isEmpty {
            let migrated = legacy
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            self.customVocabulary = migrated
            defaults.set(migrated, forKey: Keys.customVocabulary)
            defaults.removeObject(forKey: "whisperPrompt")
        } else {
            self.customVocabulary = []
        }
        self.removeFillerWords = defaults.bool(forKey: Keys.removeFillerWords)
        self.watchedFoldersEnabled = defaults.bool(forKey: Keys.watchedFoldersEnabled)
        self.watchedFolders = AppSettings.loadWatchedFolders(forKey: Keys.watchedFolders)
        self.watchedFolderNotifyOnDetect = defaults.object(forKey: Keys.watchedFolderNotifyOnDetect) as? Bool ?? true
        self.removeIgnoredSegments = defaults.object(forKey: Keys.removeIgnoredSegments) as? Bool ?? true
        self.customIgnoredSegments = defaults.stringArray(forKey: Keys.customIgnoredSegments) ?? []
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
        self.speakerIdMode = defaults.string(forKey: Keys.speakerIdMode)
            .flatMap(SpeakerIdMode.init(rawValue:)) ?? .optimistic
        self.liveTranscriptionEnabled = defaults.object(forKey: Keys.liveTranscriptionEnabled) as? Bool ?? false
        self.acousticEchoCancellation = defaults.object(forKey: Keys.acousticEchoCancellation) as? Bool ?? true
        self.prewarmWhisperOnLaunch = defaults.object(forKey: Keys.prewarmWhisperOnLaunch) as? Bool ?? false
        self.showMiniRecordingView = defaults.object(forKey: Keys.showMiniRecordingView) as? Bool ?? true
        self.showMenuBarRecordingDuration = defaults.object(forKey: Keys.showMenuBarRecordingDuration) as? Bool ?? true
        self.reduceNeon = defaults.object(forKey: Keys.reduceNeon) as? Bool ?? false
        self.lifetimeTranscribedSeconds = defaults.object(forKey: Keys.lifetimeTranscribedSeconds) as? Double ?? 0
        self.parakeetModelVariant = defaults.string(forKey: Keys.parakeetModelVariant) ?? "v3"

        self.summaryPrompt = defaults.string(forKey: Keys.summaryPrompt) ?? Self.defaultSummaryPrompt
        self.actionItemsPrompt = defaults.string(forKey: Keys.actionItemsPrompt) ?? Self.defaultActionItemsPrompt
        self.tagsPrompt = defaults.string(forKey: Keys.tagsPrompt) ?? Self.defaultTagsPrompt
        self.spokenSummaryPrompt = defaults.string(forKey: Keys.spokenSummaryPrompt) ?? Self.defaultSpokenSummaryPrompt
        self.ttsDeliveryInstruction = defaults.string(forKey: Keys.ttsDeliveryInstruction) ?? Self.defaultTTSDeliveryInstruction
        self.ttsModelSize = (defaults.string(forKey: Keys.ttsModelSize)).flatMap(TTSModelSize.init(rawValue:)) ?? .large
        self.ttsVoice = (defaults.string(forKey: Keys.ttsVoice)).flatMap(TTSVoice.init(rawValue:)) ?? .ryan
        self.ttsLanguage = (defaults.string(forKey: Keys.ttsLanguage)).flatMap(TTSLanguage.init(rawValue:)) ?? .english
        self.ttsEngine = (defaults.string(forKey: Keys.ttsEngine)).flatMap(TTSEngine.init(rawValue:)) ?? .kokoro
        self.ttsKokoroVoice = (defaults.string(forKey: Keys.ttsKokoroVoice)).flatMap(KokoroVoice.init(rawValue:)) ?? .afHeart
        self.remoteChunkingEnabled = defaults.object(forKey: Keys.remoteChunkingEnabled) as? Bool ?? true
        self.remoteChunkMaxUploadMB = max(1, defaults.object(forKey: Keys.remoteChunkMaxUploadMB) as? Int ?? 15)
        self.remoteChunkOverlapSeconds = max(
            0,
            defaults.object(forKey: Keys.remoteChunkOverlapSeconds) as? Double ?? 2.0
        )
        self.remoteChunkRetryCount = max(0, defaults.object(forKey: Keys.remoteChunkRetryCount) as? Int ?? 2)

        self.callDetectionEnabled = defaults.object(forKey: Keys.callDetectionEnabled) as? Bool ?? true
        self.autoDismissCallPromptSeconds = max(0, defaults.object(forKey: Keys.autoDismissCallPromptSeconds) as? Int ?? 0)
        if let raw = defaults.string(forKey: Keys.calendarSource),
           let source = CalendarSource(rawValue: raw) {
            self.calendarSource = source
        } else if let legacy = defaults.object(forKey: "calendarIntegrationEnabled") as? Bool {
            self.calendarSource = legacy ? .iCal : .disabled
        } else {
            self.calendarSource = .iCal
        }
        let storedCalendarMatchWindow = defaults.object(
            forKey: Keys.calendarMatchWindowMinutes
        ) as? Int ?? 15
        let normalizedCalendarMatchWindow = Self.normalizedCalendarMatchWindowMinutes(
            storedCalendarMatchWindow
        )
        self.calendarMatchWindowMinutes = normalizedCalendarMatchWindow
        if normalizedCalendarMatchWindow != storedCalendarMatchWindow {
            defaults.set(normalizedCalendarMatchWindow, forKey: Keys.calendarMatchWindowMinutes)
        }
        self.showAllMeetingsFromRecordingDay = defaults.object(
            forKey: Keys.showAllMeetingsFromRecordingDay
        ) as? Bool ?? false
        if defaults.object(forKey: Keys.selectedICalCalendarIDs) != nil {
            self.selectedICalCalendarIDs = Set(
                defaults.stringArray(forKey: Keys.selectedICalCalendarIDs) ?? []
            )
        } else {
            self.selectedICalCalendarIDs = nil
        }
        self.autoRecordCalls = defaults.object(forKey: Keys.autoRecordCalls) as? Bool ?? false
        self.disabledCallApps = Set(defaults.stringArray(forKey: Keys.disabledCallApps) ?? [])
        self.stopRecordingOnCallEnd = defaults.string(forKey: Keys.stopRecordingOnCallEnd)
            .flatMap(CallEndAction.init(rawValue:)) ?? .prompt
        self.callEndScope = defaults.string(forKey: Keys.callEndScope)
            .flatMap(CallEndScope.init(rawValue:)) ?? .callInitiatedOnly

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
