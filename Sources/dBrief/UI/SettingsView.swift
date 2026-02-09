import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var selectedTab: SettingsTab? = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case permissions = "Permissions"
        case transcription = "Transcription"
        case ai = "AI"
        case integrations = "Integrations"
        case about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gear"
            case .permissions: "lock.shield"
            case .transcription: "waveform"
            case .ai: "brain"
            case .integrations: "puzzlepiece.extension"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
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
        } detail: {
            if let tab = selectedTab {
                switch tab {
                case .general: SettingsGeneralTab()
                case .permissions: SettingsPermissionsTab()
                case .transcription: SettingsTranscriptionTab()
                case .ai: SettingsAITab()
                case .integrations: SettingsIntegrationsTab()
                case .about: AboutTab()
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
