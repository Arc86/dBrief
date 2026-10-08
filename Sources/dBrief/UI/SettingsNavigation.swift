import SwiftUI

/// Stable identifiers for routing; display labels may change independently.
/// Declaration order is sidebar order: dBrief, Capture, Understand, Deliver, footer.
enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
    case general, appearance, permissions
    case recording, meetings, watchedFolders
    case transcription, speakers, vocabulary, ai, spokenVoice
    case afterRecording, profiles, integrations, storage
    case benchmark, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .permissions: "Permissions"
        case .recording: "Recording"
        case .meetings: "Meetings"
        case .watchedFolders: "Import"
        case .transcription: "Transcription"
        case .speakers: "Speakers"
        case .vocabulary: "Vocabulary"
        case .ai: "AI analysis"
        case .spokenVoice: "Spoken summary"
        case .afterRecording: "After recording"
        case .profiles: "Profiles"
        case .integrations: "Integrations"
        case .storage: "Storage"
        case .benchmark: "Performance"
        case .about: "About"
        }
    }

    /// One line under the page title.
    var subtitle: String {
        switch self {
        case .general: "Startup, updates and the setup guide."
        case .appearance: "Theme, accent colour and interface text."
        case .permissions: "What dBrief can access on this Mac."
        case .recording: "Microphone, shortcut and what you see while recording."
        case .meetings: "Notice calls and match recordings to calendar events."
        case .watchedFolders: "Process audio files dropped into watched folders."
        case .transcription: "Turn audio into text."
        case .speakers: "Tell voices apart and recognise people you've named."
        case .vocabulary: "Names and terms dBrief should spell exactly."
        case .ai: "Summaries, action items, tags and Ask dBrief AI."
        case .spokenVoice: "Listen to a recording's summary."
        case .afterRecording: "What happens when you stop recording."
        case .profiles: "Different settings for different kinds of meetings."
        case .integrations: "Send results to the apps you work in."
        case .storage: "Where files go and how long they stay."
        case .benchmark: "How fast each model runs on this Mac."
        case .about: ""
        }
    }

    var group: SettingsGroup {
        switch self {
        case .general, .appearance, .permissions: .app
        case .recording, .meetings, .watchedFolders: .capture
        case .transcription, .speakers, .vocabulary, .ai, .spokenVoice: .understand
        case .afterRecording, .profiles, .integrations, .storage: .deliver
        case .benchmark, .about: .footer
        }
    }

    /// Sidebar top-to-bottom, footer pages last; arrow keys walk this list.
    static var sidebarOrder: [SettingsPage] { SettingsGroup.allCases.flatMap(\.pages) }

    static func adjacent(to page: SettingsPage, offset: Int) -> SettingsPage {
        let order = sidebarOrder
        guard let index = order.firstIndex(of: page) else { return page }
        return order[min(max(index + offset, 0), order.count - 1)]
    }

    var searchSection: SettingsSectionID {
        switch self {
        case .general: .appBehavior
        case .appearance: .appearance
        case .permissions: .permissions
        case .recording: .audioInput
        case .meetings: .callDetection
        case .watchedFolders: .automaticImport
        case .transcription: .transcriptionEngine
        case .speakers: .speakerIdentification
        case .vocabulary: .vocabularyTerms
        case .ai: .aiEnabled
        case .spokenVoice: .spokenVoice
        case .afterRecording: .afterRecordingTasks
        case .profiles: .profileIdentity
        case .integrations: .integrations
        case .storage: .storageFolders
        case .benchmark: .benchmark
        case .about: .about
        }
    }

    var editsAppDefaults: Bool {
        switch self {
        case .permissions, .speakers, .profiles, .benchmark, .about: false
        default: true
        }
    }

    var profileFields: [SettingsProfileScope.Field] {
        switch self {
        case .storage: [.recordingFolder, .transcriptFolder]
        case .transcription: [.language, .transcriptionEngine, .transcriptionService]
        case .vocabulary: [.vocabulary]
        case .meetings: [.calendarEffort]
        case .ai: [.aiEnabled, .aiEngine, .aiProvider, .analysisEffort, .summaryPrompt, .actionsPrompt, .tagsPrompt]
        case .afterRecording: [.transcriptionTask, .summaryTask, .actionsTask, .tagsTask]
        case .integrations: [.obsidianVault, .obsidianFolder]
        default: []
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .permissions: "checkmark.shield"
        case .recording: "mic"
        case .meetings: "video"
        case .watchedFolders: "tray.and.arrow.down"
        case .transcription: "waveform"
        case .speakers: "person.wave.2"
        case .vocabulary: "character.book.closed"
        case .ai: "sparkles"
        case .spokenVoice: "speaker.wave.2"
        case .afterRecording: "checklist"
        case .profiles: "person.3"
        case .integrations: "puzzlepiece.extension"
        case .storage: "internaldrive"
        case .benchmark: "gauge.with.dots.needle.33percent"
        case .about: "info.circle"
        }
    }
}

enum SettingsGroup: String, CaseIterable, Identifiable, Sendable {
    case app, capture, understand, deliver, footer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .app: "dBrief"
        case .capture: "Capture"
        case .understand: "Understand"
        case .deliver: "Deliver"
        case .footer: ""
        }
    }
    var pages: [SettingsPage] { SettingsPage.allCases.filter { $0.group == self } }
}

enum SettingsSectionID: String, CaseIterable, Sendable {
    case appBehavior, softwareUpdate, setupGuide
    case appearance, accentColor, typography
    case recordingShortcut, audioInput, echoCancellation, recordingIndicators, audioQuality
    case callDetection, callPlatforms, calendar, meetingMatching, calendarCLIAdvanced
    case integrations
    case storageFolders
    case afterRecordingTasks, afterRecordingAutomation
    case transcriptionEngine, transcriptionLanguage, transcriptionCleanup, transcriptionLive, transcriptionServices, transcriptionChunking, transcriptionAdvanced
    case speakerIdentification, speakerLibrary
    case aiEnabled, aiEngine, aiResultsLanguage, aiPrompts, aiCLI, aiChatFallback, aiProviders
    case spokenVoice, spokenPrompt, vocabularyTerms, automaticImport, permissions, benchmark, about
    case profileIdentity, profileMatching, profileAutomation, profileTranscription, profileAI, profileTasks, profileFolders

    var page: SettingsPage {
        switch self {
        case .transcriptionEngine, .transcriptionLanguage, .transcriptionCleanup, .transcriptionLive,
             .transcriptionServices, .transcriptionChunking, .transcriptionAdvanced: .transcription
        case .aiEnabled, .aiEngine, .aiResultsLanguage, .aiPrompts, .aiCLI, .aiChatFallback, .aiProviders: .ai
        case .speakerIdentification, .speakerLibrary: .speakers
        case .benchmark: .benchmark
        case .about: .about
        case .spokenVoice, .spokenPrompt: .spokenVoice
        case .vocabularyTerms: .vocabulary
        case .automaticImport: .watchedFolders
        case .permissions: .permissions
        case .appBehavior, .softwareUpdate, .setupGuide: .general
        case .appearance, .accentColor, .typography: .appearance
        case .recordingShortcut, .audioInput, .echoCancellation, .recordingIndicators, .audioQuality: .recording
        case .callDetection, .callPlatforms, .calendar, .meetingMatching, .calendarCLIAdvanced: .meetings
        case .integrations: .integrations
        case .storageFolders: .storage
        case .afterRecordingTasks, .afterRecordingAutomation: .afterRecording
        case .profileIdentity, .profileMatching, .profileAutomation, .profileTranscription, .profileAI, .profileTasks, .profileFolders: .profiles
        }
    }

    /// Sections that live inside a page's collapsed Advanced card.
    var isAdvanced: Bool {
        switch self {
        case .audioQuality, .transcriptionAdvanced, .transcriptionChunking, .aiPrompts, .spokenPrompt, .calendarCLIAdvanced: true
        default: false
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
