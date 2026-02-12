import Foundation

enum ProfilePresetKind: String, Codable, CaseIterable, Sendable {
    case `default`
    case teamMeeting
    case salesMeeting
    case custom
}

struct MeetingProfileOverrides: Codable, Hashable, Sendable {
    var transcriptionLanguage: String?
    var whisperPrompt: String?
    var transcriptionEngine: AppSettings.TranscriptionEngine?
    var transcriptionEndpointId: UUID?
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

    static let empty = MeetingProfileOverrides()
}

struct MeetingProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var preset: ProfilePresetKind
    var overrides: MeetingProfileOverrides

    init(
        id: UUID = UUID(),
        name: String,
        preset: ProfilePresetKind = .custom,
        overrides: MeetingProfileOverrides = .empty
    ) {
        self.id = id
        self.name = name
        self.preset = preset
        self.overrides = overrides
    }

    var isProtectedDefault: Bool { preset == .default }
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
