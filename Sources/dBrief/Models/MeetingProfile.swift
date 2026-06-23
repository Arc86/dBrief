import Foundation

enum ProfilePresetKind: String, Codable, CaseIterable, Sendable {
    case `default`
    case teamMeeting
    case salesMeeting
    case custom
}

struct MeetingProfileOverrides: Codable, Equatable, Hashable, Sendable {
    var transcriptionLanguage: String?
    var customVocabulary: [String]?
    var transcriptionEngine: AppSettings.TranscriptionEngine?
    var transcriptionEndpointId: UUID?
    var aiProcessingEnabled: Bool?
    var aiEngine: AppSettings.AIEngine?
    var aiEndpointId: UUID?
    var summaryPrompt: String?
    var actionItemsPrompt: String?
    var tagsPrompt: String?
    var autoTranscribe: Bool?
    var autoSummary: Bool?
    var autoActionItems: Bool?
    var autoTags: Bool?
    var recordingFolderPath: String?
    var transcriptionFolderPath: String?
    var obsidianVaultPath: String?
    var obsidianDefaultFolderRelativePath: String?

    // swiftlint:disable:next function_default_parameter_at_end
    init(
        transcriptionLanguage: String? = nil,
        customVocabulary: [String]? = nil,
        transcriptionEngine: AppSettings.TranscriptionEngine? = nil,
        transcriptionEndpointId: UUID? = nil,
        aiProcessingEnabled: Bool? = nil,
        aiEngine: AppSettings.AIEngine? = nil,
        aiEndpointId: UUID? = nil,
        summaryPrompt: String? = nil,
        actionItemsPrompt: String? = nil,
        tagsPrompt: String? = nil,
        autoTranscribe: Bool? = nil,
        autoSummary: Bool? = nil,
        autoActionItems: Bool? = nil,
        autoTags: Bool? = nil,
        recordingFolderPath: String? = nil,
        transcriptionFolderPath: String? = nil,
        obsidianVaultPath: String? = nil,
        obsidianDefaultFolderRelativePath: String? = nil
    ) {
        self.transcriptionLanguage = transcriptionLanguage
        self.customVocabulary = customVocabulary
        self.transcriptionEngine = transcriptionEngine
        self.transcriptionEndpointId = transcriptionEndpointId
        self.aiProcessingEnabled = aiProcessingEnabled
        self.aiEngine = aiEngine
        self.aiEndpointId = aiEndpointId
        self.summaryPrompt = summaryPrompt
        self.actionItemsPrompt = actionItemsPrompt
        self.tagsPrompt = tagsPrompt
        self.autoTranscribe = autoTranscribe
        self.autoSummary = autoSummary
        self.autoActionItems = autoActionItems
        self.autoTags = autoTags
        self.recordingFolderPath = recordingFolderPath
        self.transcriptionFolderPath = transcriptionFolderPath
        self.obsidianVaultPath = obsidianVaultPath
        self.obsidianDefaultFolderRelativePath = obsidianDefaultFolderRelativePath
    }

    static let empty = MeetingProfileOverrides()

    // Legacy key used only in decoding migration
    private enum LegacyKeys: String, CodingKey { case whisperPrompt }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcriptionLanguage = try c.decodeIfPresent(String.self, forKey: .transcriptionLanguage)
        transcriptionEngine = try c.decodeIfPresent(AppSettings.TranscriptionEngine.self, forKey: .transcriptionEngine)
        transcriptionEndpointId = try c.decodeIfPresent(UUID.self, forKey: .transcriptionEndpointId)
        aiProcessingEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiProcessingEnabled)
        aiEngine = try c.decodeIfPresent(AppSettings.AIEngine.self, forKey: .aiEngine)
        aiEndpointId = try c.decodeIfPresent(UUID.self, forKey: .aiEndpointId)
        summaryPrompt = try c.decodeIfPresent(String.self, forKey: .summaryPrompt)
        actionItemsPrompt = try c.decodeIfPresent(String.self, forKey: .actionItemsPrompt)
        tagsPrompt = try c.decodeIfPresent(String.self, forKey: .tagsPrompt)
        autoTranscribe = try c.decodeIfPresent(Bool.self, forKey: .autoTranscribe)
        autoSummary = try c.decodeIfPresent(Bool.self, forKey: .autoSummary)
        autoActionItems = try c.decodeIfPresent(Bool.self, forKey: .autoActionItems)
        autoTags = try c.decodeIfPresent(Bool.self, forKey: .autoTags)
        recordingFolderPath = try c.decodeIfPresent(String.self, forKey: .recordingFolderPath)
        transcriptionFolderPath = try c.decodeIfPresent(String.self, forKey: .transcriptionFolderPath)
        obsidianVaultPath = try c.decodeIfPresent(String.self, forKey: .obsidianVaultPath)
        obsidianDefaultFolderRelativePath = try c.decodeIfPresent(String.self, forKey: .obsidianDefaultFolderRelativePath)

        if let vocab = try c.decodeIfPresent([String].self, forKey: .customVocabulary) {
            customVocabulary = vocab
        } else {
            // Migrate legacy "whisperPrompt" string → [String]
            let legacyC = try decoder.container(keyedBy: LegacyKeys.self)
            if let legacy = try legacyC.decodeIfPresent(String.self, forKey: .whisperPrompt),
               !legacy.isEmpty
            {
                customVocabulary = legacy
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else {
                customVocabulary = nil
            }
        }
    }
}

struct MeetingProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var iconSystemName: String
    var iconBackgroundColorKey: String
    var preset: ProfilePresetKind
    var overrides: MeetingProfileOverrides

    init(
        id: UUID = UUID(),
        name: String,
        iconSystemName: String? = nil,
        iconBackgroundColorKey: String? = nil,
        preset: ProfilePresetKind = .custom,
        overrides: MeetingProfileOverrides = .empty
    ) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName ?? Self.defaultIcon(for: preset)
        self.iconBackgroundColorKey = iconBackgroundColorKey ?? Self.defaultIconBackgroundColor(for: preset)
        self.preset = preset
        self.overrides = overrides
    }

    var isProtectedDefault: Bool { preset == .default }

    static func defaultIcon(for preset: ProfilePresetKind) -> String {
        switch preset {
        case .default:
            "slider.horizontal.3"
        case .teamMeeting:
            "person.3.fill"
        case .salesMeeting:
            "briefcase.fill"
        case .custom:
            "person.crop.square.fill"
        }
    }

    static func defaultIconBackgroundColor(for preset: ProfilePresetKind) -> String {
        switch preset {
        case .default:
            "blue"
        case .teamMeeting:
            "indigo"
        case .salesMeeting:
            "green"
        case .custom:
            "gray"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case iconSystemName
        case iconBackgroundColorKey
        case preset
        case overrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        preset = try container.decode(ProfilePresetKind.self, forKey: .preset)
        overrides = try container.decodeIfPresent(MeetingProfileOverrides.self, forKey: .overrides) ?? .empty
        iconSystemName = try container.decodeIfPresent(String.self, forKey: .iconSystemName)
            ?? Self.defaultIcon(for: preset)
        iconBackgroundColorKey = try container.decodeIfPresent(String.self, forKey: .iconBackgroundColorKey)
            ?? Self.defaultIconBackgroundColor(for: preset)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(iconSystemName, forKey: .iconSystemName)
        try container.encode(iconBackgroundColorKey, forKey: .iconBackgroundColorKey)
        try container.encode(preset, forKey: .preset)
        try container.encode(overrides, forKey: .overrides)
    }
}

struct ProfilesExportEnvelope: Codable, Sendable {
    var version: Int
    var exportedAtISO8601: String
    var profiles: [MeetingProfile]
}

struct ImportResult: Sendable {
    var importedCount: Int
    var renamedCount: Int
    var warnings: [String]
}

enum ProfileImportError: Error, LocalizedError {
    case invalidVersion(Int)
    case emptyImport
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidVersion(let version):
            "Unsupported profile import version: \(version)."
        case .emptyImport:
            "No profiles found in the import file."
        case .invalidFormat:
            "Invalid profiles JSON format."
        }
    }
}
