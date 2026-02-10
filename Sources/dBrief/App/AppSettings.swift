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

    enum TranscriptionEngine: String, CaseIterable, Sendable {
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

    /// Preferred transcription engine (Apple Speech, Local Whisper, or remote endpoint).
    var transcriptionEngine: TranscriptionEngine {
        didSet { UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) }
    }

    /// Use built-in Apple Intelligence instead of an external endpoint (macOS 26+)
    var useBuiltInAI: Bool {
        didSet { UserDefaults.standard.set(useBuiltInAI, forKey: Keys.useBuiltInAI) }
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

    var summaryPrompt: String {
        didSet { UserDefaults.standard.set(summaryPrompt, forKey: Keys.summaryPrompt) }
    }

    var actionItemsPrompt: String {
        didSet { UserDefaults.standard.set(actionItemsPrompt, forKey: Keys.actionItemsPrompt) }
    }

    var tagsPrompt: String {
        didSet { UserDefaults.standard.set(tagsPrompt, forKey: Keys.tagsPrompt) }
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

        self.useBuiltInAI = defaults.bool(forKey: Keys.useBuiltInAI)

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
        guard let vaultURL = obsidianVaultURL?.standardizedFileURL else { return nil }
        let vaultPath = vaultURL.path
        let folderPath = folderURL.standardizedFileURL.path

        if folderPath == vaultPath { return "" }
        guard folderPath.hasPrefix(vaultPath + "/") else { return nil }
        return String(folderPath.dropFirst(vaultPath.count + 1))
    }

    func obsidianFolderURL(relativePath: String?) -> URL? {
        guard let vaultURL = obsidianVaultURL else { return nil }
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
}
