import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var selectedTab: SettingsTab? = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general        = "General"
        case recording      = "Recording"
        case aiAndModels    = "AI & Models"
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
            case .aiAndModels:    "brain"
            case .vocabulary:     "text.word.spacing"
            case .watchedFolders: "folder.badge.gearshape"
            case .integrations:   "puzzlepiece.extension"
            case .voiceLibrary:   "person.wave.2"
            case .profiles:       "person.3"
            case .benchmark:      "speedometer"
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
                } icon: {
                    Image(systemName: tab.icon)
                        .imageScale(.large)
                }
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
                case .aiAndModels:  SettingsAIModelsTab()
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
