import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case integrations = "Integrations"
        case transcription = "Transcription"
        case ai = "AI"
        case about = "About"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gear"
            case .integrations: "puzzlepiece.extension"
            case .transcription: "waveform"
            case .ai: "brain"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selectedTab {
                case .general:
                    SettingsGeneralTab()
                case .integrations:
                    SettingsIntegrationsTab()
                case .transcription:
                    SettingsTranscriptionTab()
                case .ai:
                    SettingsAITab()
                case .about:
                    AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
        }
        .frame(width: 600, height: 420)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Voice Recorder")
                .font(.title)

            Text("Version 1.0.0")
                .foregroundStyle(.secondary)

            Text("A macOS menu bar app for recording,\ntranscribing, and analyzing voice recordings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
