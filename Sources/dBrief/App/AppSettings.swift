import Foundation
import SwiftUI

@MainActor
@Observable
final class AppSettings {
    // MARK: - Storage Keys

    private enum Keys {
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
        static let obsidianEnabled = "obsidianEnabled"
        static let obsidianDefaultFolderRelativePath = "obsidianDefaultFolderRelativePath"
        static let integrationSettings = "integrationSettings"
        static let showDockIcon = "showDockIcon"
        static let profiles = "profiles"
        static let activeProfileId = "activeProfileId"
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
            case .qwenLocal: "Qwen 2.5 Local"
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
        didSet {
            UserDefaults.standard.set(aiEngine.rawValue, forKey: Keys.aiEngine)
            UserDefaults.standard.set(aiEngine == .appleIntelligence, forKey: Keys.useBuiltInAI)
        }
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

    /// Backward-compatible bridge for existing views that still use the old boolean key.
    var useBuiltInAI: Bool {
        get { aiEngine == .appleIntelligence }
        set { aiEngine = newValue ? .appleIntelligence : .remoteEndpoint }
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
        Provide a clear, concise summary of the key discussion points, decisions, and outcomes. \
        Use bullet points. Keep the summary brief but comprehensive.
        """

    static let defaultActionItemsPrompt = """
        You are an assistant that extracts action items from meeting transcriptions. \
        List each action item as a separate line starting with "- ". \
        Include who is responsible if mentioned. \
        Only output the action items, nothing else.
        """

    static let defaultTagsPrompt = """
        You are an assistant that analyzes meeting transcriptions. \
        Output a JSON object with two fields: \
        "tags" (array of 3-7 relevant topic tags, lowercase, no # prefix) and \
        "sentiment" (one of: "positive", "neutral", "negative", "mixed"). \
        Only output valid JSON, nothing else.
        """

    static let teamMeetingWhisperPrompt =
        "Team standup, sprint, backlog, blocker, follow-up, ETA, Jira, PR, release, roadmap, architecture."

    static let teamMeetingSummaryPrompt =
        "Summarize this internal team meeting in concise bullet points. Include: decisions, progress updates, blockers, and next steps. Keep tone informal and practical."

    static let teamMeetingActionItemsPrompt =
        "Extract concrete action items from this team meeting. Output bullet lines beginning with '- '. Include owner if mentioned and due date if mentioned. Keep wording short."

    static let teamMeetingTagsPrompt =
        "Return valid JSON only: {\"tags\": [...], \"sentiment\": \"...\"}. Tags should reflect internal collaboration topics (planning, delivery, blockers, risks, dependencies)."

    static let salesMeetingWhisperPrompt =
        "Customer, contract, pricing, procurement, renewal, objections, competitor, timeline, stakeholder, action item, follow-up."

    static let salesMeetingSummaryPrompt =
        "Create a formal customer-facing sales meeting summary. Prioritize factual accuracy, commitments, risks, and agreed commercial points. Use clear bullet points."

    static let salesMeetingActionItemsPrompt =
        "Extract precise action items for sales follow-up. Output bullet lines beginning with '- '. Include owner, expected outcome, and date when available. Be exact and unambiguous."

    static let salesMeetingTagsPrompt =
        "Return valid JSON only: {\"tags\": [...], \"sentiment\": \"...\"}. Tags should focus on deal stage, customer needs, objections, budget, timeline, decision process, and next steps."

    var summaryPrompt: String {
        didSet { UserDefaults.standard.set(summaryPrompt, forKey: Keys.summaryPrompt) }
    }

    var actionItemsPrompt: String {
        didSet { UserDefaults.standard.set(actionItemsPrompt, forKey: Keys.actionItemsPrompt) }
    }

    var tagsPrompt: String {
        didSet { UserDefaults.standard.set(tagsPrompt, forKey: Keys.tagsPrompt) }
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

    func setActiveProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileId = id
    }

    @discardableResult
    func createProfile(name: String) -> MeetingProfile {
        let uniqueName = uniqueProfileName(from: name)
        let profile = MeetingProfile(name: uniqueName)
        profiles.append(profile)
        return profile
    }

    func deleteProfile(id: UUID) {
        guard let existing = profiles.first(where: { $0.id == id }) else { return }
        guard !existing.isProtectedDefault else { return }
        profiles.removeAll { $0.id == id }
        if activeProfileId == id, let fallback = profiles.first(where: { $0.preset == .default }) ?? profiles.first {
            activeProfileId = fallback.id
        }
    }

    func resetDefaultProfileToBuiltInDefaults() {
        guard let index = profiles.firstIndex(where: { $0.preset == .default }) else { return }
        profiles[index].overrides = .empty
        profiles[index].name = "Default"

        transcriptionLanguage = ""
        whisperPrompt = ""
        summaryPrompt = Self.defaultSummaryPrompt
        actionItemsPrompt = Self.defaultActionItemsPrompt
        tagsPrompt = Self.defaultTagsPrompt
        autoTranscribe = true
        autoSummary = true
        autoActionItems = true
        autoTags = true
        recordingFolderURL = Self.defaultRecordingFolder()
        transcriptionFolderURL = Self.defaultTranscriptionFolder()
        obsidianVaultURL = nil
        obsidianDefaultFolderRelativePath = ""
    }

    func importProfiles(from data: Data) throws -> ImportResult {
        let envelope: ProfilesExportEnvelope
        do {
            envelope = try JSONDecoder().decode(ProfilesExportEnvelope.self, from: data)
        } catch {
            throw ProfileImportError.invalidFormat
        }

        guard envelope.version == 1 else {
            throw ProfileImportError.invalidVersion(envelope.version)
        }
        guard !envelope.profiles.isEmpty else {
            throw ProfileImportError.emptyImport
        }

        var renamedCount = 0
        var warnings: [String] = []
        var workingProfiles = profiles

        for sourceProfile in envelope.profiles {
            var profile = sourceProfile
            if profile.preset == .default {
                profile.preset = .custom
                warnings.append("Imported default profile was converted to custom.")
            }

            let newName = uniqueImportedProfileName(from: profile.name, existing: workingProfiles)
            if newName != profile.name {
                renamedCount += 1
                profile.name = newName
            }

            profile.id = UUID()
            workingProfiles.append(profile)
        }

        profiles = workingProfiles
        return ImportResult(
            importedCount: envelope.profiles.count,
            renamedCount: renamedCount,
            warnings: warnings
        )
    }

    func exportProfiles(ids: [UUID]? = nil) throws -> Data {
        let selectedProfiles: [MeetingProfile]
        if let ids {
            let allowed = Set(ids)
            selectedProfiles = profiles.filter { allowed.contains($0.id) }
        } else {
            selectedProfiles = profiles
        }

        let envelope = ProfilesExportEnvelope(
            version: 1,
            exportedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            profiles: selectedProfiles
        )
        return try JSONEncoder().encode(envelope)
    }

    func warnings(for profile: MeetingProfile) -> [String] {
        var values: [String] = []
        if let endpointID = profile.overrides.transcriptionEndpointId,
           !transcriptionEndpoints.contains(where: { $0.id == endpointID })
        {
            values.append("Transcription endpoint override not found; default endpoint will be used.")
        }
        if let endpointID = profile.overrides.aiEndpointId,
           !aiEndpoints.contains(where: { $0.id == endpointID })
        {
            values.append("AI endpoint override not found; default endpoint will be used.")
        }
        if let path = profile.overrides.obsidianVaultPath,
           !path.isEmpty,
           !FileManager.default.fileExists(atPath: path)
        {
            values.append("Obsidian vault override path is unavailable; default vault will be used.")
        }
        return values
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

        self.transcriptionLanguage = defaults.string(forKey: Keys.transcriptionLanguage) ?? ""
        self.whisperPrompt = defaults.string(forKey: Keys.whisperPrompt) ?? ""

        self.summaryPrompt = defaults.string(forKey: Keys.summaryPrompt) ?? Self.defaultSummaryPrompt
        self.actionItemsPrompt = defaults.string(forKey: Keys.actionItemsPrompt) ?? Self.defaultActionItemsPrompt
        self.tagsPrompt = defaults.string(forKey: Keys.tagsPrompt) ?? Self.defaultTagsPrompt

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

    // MARK: - Bookmark Persistence

    private func saveBookmark(for url: URL, key: String) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func saveBookmark(for url: URL?, key: String) {
        guard let url else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        saveBookmark(for: url, key: key)
    }

    private static func loadBookmarkURL(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    func obsidianRelativePath(for folderURL: URL) -> String? {
        guard let vaultURL = effectiveObsidianVaultURL?.standardizedFileURL else { return nil }
        let vaultPath = vaultURL.path
        let folderPath = folderURL.standardizedFileURL.path

        if folderPath == vaultPath { return "" }
        guard folderPath.hasPrefix(vaultPath + "/") else { return nil }
        return String(folderPath.dropFirst(vaultPath.count + 1))
    }

    func obsidianFolderURL(relativePath: String?) -> URL? {
        guard let vaultURL = effectiveObsidianVaultURL else { return nil }
        let trimmed = (relativePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return vaultURL }
        let sanitized = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return vaultURL.appendingPathComponent(sanitized, isDirectory: true)
    }

    func obsidianFolderDisplayName(relativePath: String?) -> String {
        let trimmed = (relativePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Vault root" : trimmed
    }

    private static func defaultRecordingFolder() -> URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dBrief/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func defaultTranscriptionFolder() -> URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dBrief/Transcriptions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func resolvedFolderURL(overridePath: String?, fallback: URL) -> URL {
        guard let overridePath else { return fallback }
        let trimmed = overridePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        let url = URL(fileURLWithPath: trimmed, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return fallback
        }
    }

    // MARK: - Endpoint Persistence

    private func saveEndpoints(_ endpoints: [Endpoint], forKey key: String) {
        if let data = try? JSONEncoder().encode(endpoints) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadEndpoints(forKey key: String) -> [Endpoint] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let endpoints = try? JSONDecoder().decode([Endpoint].self, from: data)
        else { return [] }
        return endpoints
    }

    // MARK: - Integration Settings Persistence

    private func saveIntegrationSettings(_ settings: IntegrationSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Keys.integrationSettings)
        }
    }

    private static func loadIntegrationSettings(forKey key: String) -> IntegrationSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(IntegrationSettings.self, from: data)
        else { return IntegrationSettings() }
        return value
    }

    // MARK: - Profiles Persistence

    private func saveProfiles(_ values: [MeetingProfile]) {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: Keys.profiles)
        }
    }

    private static func loadProfiles(forKey key: String) -> [MeetingProfile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode([MeetingProfile].self, from: data)
        else { return [] }
        return values
    }

    private static func defaultProfile() -> MeetingProfile {
        MeetingProfile(name: "Default", preset: .default)
    }

    private static func teamMeetingProfile() -> MeetingProfile {
        MeetingProfile(
            name: "Team meeting",
            preset: .teamMeeting,
            overrides: MeetingProfileOverrides(
                whisperPrompt: teamMeetingWhisperPrompt,
                summaryPrompt: teamMeetingSummaryPrompt,
                actionItemsPrompt: teamMeetingActionItemsPrompt,
                tagsPrompt: teamMeetingTagsPrompt,
                autoSummary: true,
                autoActionItems: true,
                autoTags: true
            )
        )
    }

    private static func salesMeetingProfile() -> MeetingProfile {
        MeetingProfile(
            name: "Sales meeting",
            preset: .salesMeeting,
            overrides: MeetingProfileOverrides(
                whisperPrompt: salesMeetingWhisperPrompt,
                summaryPrompt: salesMeetingSummaryPrompt,
                actionItemsPrompt: salesMeetingActionItemsPrompt,
                tagsPrompt: salesMeetingTagsPrompt,
                autoSummary: true,
                autoActionItems: true,
                autoTags: true
            )
        )
    }

    private static func builtInProfiles() -> [MeetingProfile] {
        [defaultProfile(), teamMeetingProfile(), salesMeetingProfile()]
    }

    private func uniqueProfileName(from baseName: String, existing: [MeetingProfile]? = nil) -> String {
        let values = existing ?? profiles
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "Profile" : trimmed
        let existingNames = Set(values.map { $0.name.lowercased() })
        if !existingNames.contains(candidate.lowercased()) {
            return candidate
        }

        var index = 1
        while true {
            let suffix = " \(index + 1)"
            let nextName = candidate + suffix
            if !existingNames.contains(nextName.lowercased()) {
                return nextName
            }
            index += 1
        }
    }

    private func uniqueImportedProfileName(from baseName: String, existing: [MeetingProfile]) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "Profile" : trimmed
        let existingNames = Set(existing.map { $0.name.lowercased() })
        if !existingNames.contains(candidate.lowercased()) {
            return candidate
        }

        var index = 1
        while true {
            let suffix = index == 1 ? " (Imported)" : " (Imported \(index))"
            let nextName = candidate + suffix
            if !existingNames.contains(nextName.lowercased()) {
                return nextName
            }
            index += 1
        }
    }
}
