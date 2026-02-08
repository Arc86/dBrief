import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case transcription = "Transcription"
        case ai = "AI"
        case integrations = "Integrations"
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

            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 96, height: 96)
            } else {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)
            }

            Text("DeBrief Version 1.1.0")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Automated meeting intelligence for sales teams. Capture discovery calls, generate AI summaries, and sync action items directly to your Obsidian vault.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("[Check for Updates]")
                Text("•")
                    .foregroundStyle(.secondary)
                Text("[Support]")
                Text("•")
                    .foregroundStyle(.secondary)
                Text("[Documentation]")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
