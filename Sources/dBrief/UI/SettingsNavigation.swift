import SwiftUI

/// Stable identifiers for routing; display labels may change independently.
enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
    case general
    case recording
    case transcription
    case ai
    case spokenVoice
    case vocabulary
    case watchedFolders
    case integrations
    case voiceLibrary
    case profiles
    case benchmark
    case permissions
    case about
    case storage
    case afterRecording
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .transcription: "Transcription"
        case .ai: "AI Analysis"
        case .spokenVoice: "Spoken Summary"
        case .vocabulary: "Vocabulary"
        case .watchedFolders: "Automatic Import"
        case .integrations: "Integrations"
        case .voiceLibrary: "Speaker Library"
        case .profiles: "Profiles"
        case .benchmark: "Benchmark"
        case .permissions: "Permissions"
        case .about: "About"
        case .storage: "Storage"
        case .afterRecording: "After Recording"
        }
    }
    var group: SettingsGroup {
        switch self {
        case .general, .storage, .permissions, .about: .app
        case .recording, .watchedFolders: .recording
        case .transcription, .ai, .spokenVoice, .vocabulary, .voiceLibrary, .benchmark: .processing
        case .afterRecording, .profiles, .integrations: .workflow
        }
    }
    static func visiblePages(advanced: Bool) -> [Self] {
        allCases.filter { $0 != .benchmark || advanced }
    }
    func visibleSelection(advanced: Bool) -> Self {
        self == .benchmark && !advanced ? .general : self
    }
    var searchSection: SettingsSectionID {
        switch self {
        case .general: .appearance
        case .recording: .audioInput
        case .storage: .storageFolders
        case .transcription: .transcriptionEngine
        case .ai: .aiEnabled
        case .spokenVoice: .spokenVoice
        case .vocabulary: .vocabularyTerms
        case .watchedFolders: .automaticImport
        case .integrations: .integrations
        case .voiceLibrary: .speakerLibrary
        case .profiles: .profileIdentity
        case .benchmark: .benchmark
        case .permissions: .permissions
        case .about: .about
        case .afterRecording: .afterRecordingTasks
        }
    }
    var editsAppDefaults: Bool {
        switch self {
        case .general, .recording, .transcription, .ai, .spokenVoice, .vocabulary, .watchedFolders, .integrations, .storage, .afterRecording: true
        default: false
        }
    }
    var profileFields: [SettingsProfileScope.Field] {
        switch self {
        case .storage: [.recordingFolder, .transcriptFolder]
        case .transcription: [.language, .transcriptionEngine, .transcriptionService]
        case .vocabulary: [.vocabulary]
        case .ai: [.aiEnabled, .aiEngine, .aiProvider, .summaryPrompt, .actionsPrompt, .tagsPrompt]
        case .afterRecording: [.transcriptionTask, .summaryTask, .actionsTask, .tagsTask]
        case .integrations: [.obsidianVault, .obsidianFolder]
        default: []
        }
    }
    var icon: String {
        switch self {
        case .storage:        "internaldrive"
        case .afterRecording: "checklist"
        case .general:        "gear"
        case .permissions:    "lock.shield"
        case .about:          "info.circle"
        case .recording:      "mic"
        case .transcription:  "waveform"
        case .ai:             "brain"
        case .spokenVoice:    "speaker.wave.2"
        case .vocabulary:     "text.word.spacing"
        case .watchedFolders: "folder.badge.gearshape"
        case .integrations:   "puzzlepiece.extension"
        case .voiceLibrary:   "person.wave.2"
        case .profiles:       "person.3"
        case .benchmark:      "speedometer"
        }
    }

    /// Background tint for the System Settings–style colored icon badge.
    var color: Color {
        switch self {
        case .storage:        .brown
        case .afterRecording: .indigo
        case .general:        .gray
        case .recording:      .red
        case .transcription:  .blue
        case .ai:             .purple
        case .spokenVoice:    .pink
        case .vocabulary:     .indigo
        case .watchedFolders: .orange
        case .integrations:   .teal
        case .voiceLibrary:   .cyan
        case .profiles:       .mint
        case .benchmark:      .green
        case .permissions:    .gray
        case .about:          .blue
        }
    }
}


enum SettingsGroup: String, CaseIterable, Identifiable, Sendable {
    case app, recording, processing, workflow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .app: "App"
        case .recording: "Recording"
        case .processing: "Processing"
        case .workflow: "Workflow"
        }
    }
    var pages: [SettingsPage] {
        switch self {
        case .app: [.general, .storage, .permissions, .about]
        case .recording: [.recording, .watchedFolders]
        case .processing: [.transcription, .ai, .spokenVoice, .vocabulary, .voiceLibrary, .benchmark]
        case .workflow: [.afterRecording, .profiles, .integrations]
        }
    }
}

enum SettingsSectionID: String, CaseIterable, Sendable {
    case appearance, softwareUpdate, setupGuide
    case recordingShortcut, callDetection, callPlatforms, audioInput, echoCancellation, recordingIndicators, audioQuality
    case calendar, integrations
    case storageFolders
    case afterRecordingTasks, afterRecordingAutomation
    case transcriptionEngine, transcriptionLanguage, transcriptionCleanup, transcriptionLive, transcriptionServices, transcriptionChunking
    case aiEnabled, aiEngine, aiPrompts, aiCLI, aiChatFallback, aiProviders
    case spokenVoice, spokenPrompt, vocabularyTerms, automaticImport, permissions, speakerLibrary, benchmark, about
    case profileIdentity, profileMatching, profileAutomation, profileTranscription, profileAI, profileTasks, profileFolders

    var page: SettingsPage {
        switch self {
        case .transcriptionEngine, .transcriptionLanguage, .transcriptionCleanup, .transcriptionLive, .transcriptionServices, .transcriptionChunking: .transcription
        case .aiEnabled, .aiEngine, .aiPrompts, .aiCLI, .aiChatFallback, .aiProviders: .ai
        case .speakerLibrary: .voiceLibrary
        case .benchmark: .benchmark
        case .about: .about
        case .spokenVoice, .spokenPrompt: .spokenVoice
        case .vocabularyTerms: .vocabulary
        case .automaticImport: .watchedFolders
        case .permissions: .permissions
        case .appearance, .softwareUpdate, .setupGuide: .general
        case .recordingShortcut, .callDetection, .callPlatforms, .audioInput, .echoCancellation, .recordingIndicators, .audioQuality: .recording
        case .calendar, .integrations: .integrations
        case .storageFolders: .storage
        case .afterRecordingTasks, .afterRecordingAutomation: .afterRecording
        case .profileIdentity, .profileMatching, .profileAutomation, .profileTranscription, .profileAI, .profileTasks, .profileFolders: .profiles
        }
    }
}

struct SettingsDestination: Equatable, Sendable {
    let page: SettingsPage
    let section: SettingsSectionID?

    init(page: SettingsPage) {
        self.page = page
        self.section = nil
    }

    init(section: SettingsSectionID) {
        self.page = section.page
        self.section = section
    }
}
