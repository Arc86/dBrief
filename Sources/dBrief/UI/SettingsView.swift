import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var selectedTab: SettingsTab? = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general        = "General"
        case recording      = "Recording"
        case transcription  = "Transcription"
        case ai             = "AI Analysis"
        case spokenVoice    = "Spoken Summary"
        case vocabulary     = "Vocabulary"
        case watchedFolders = "Watched Folders"
        case integrations   = "Integrations"
        case voiceLibrary   = "Voice Library"
        case profiles       = "Profiles"
        case benchmark      = "Benchmark"
        case permissions    = "Permissions"
        case about          = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
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

    private var visibleTabs: [SettingsTab] {
        SettingsTab.allCases.filter { tab in
            if tab == .profiles || tab == .benchmark { return appSettings.powerUserMode }
            return true
        }
    }

    var body: some View {
        NavigationSplitView {
            List(visibleTabs, selection: $selectedTab) { tab in
                Label {
                    Text(tab.rawValue)
                        .font(.system(size: 14))
                } icon: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(tab.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.vertical, 3)
                .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
            Divider()
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("dBrief v\(version)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        } detail: {
            if let tab = selectedTab {
                switch tab {
                case .general:      SettingsGeneralTab()
                case .permissions:  SettingsPermissionsTab()
                case .recording:    SettingsRecordingTab()
                case .transcription: SettingsTranscriptionTab()
                case .ai:           SettingsAITab()
                case .spokenVoice:  SettingsSpokenVoiceTab()
                case .vocabulary:     SettingsVocabularyTab()
                case .watchedFolders: SettingsWatchedFoldersTab()
                case .integrations: SettingsIntegrationsTab()
                case .voiceLibrary: SettingsVoiceLibraryTab()
                case .profiles:     SettingsProfilesTab()
                case .benchmark:    SettingsBenchmarkTab()
                case .about:        AboutTab()
                }
            } else {
                SettingsGeneralTab()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            if !appSettings.showDockIcon {
                NSApp.setActivationPolicy(.regular)
            }
        }
        .onDisappear {
            if !appSettings.showDockIcon {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
