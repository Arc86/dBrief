import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

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
                case .permissions:
                    SettingsPermissionsTab()
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
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.88, green: 0.95, blue: 0.96),
                        Color(red: 0.78, green: 0.90, blue: 0.92),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack {
                    Spacer()

                    VStack(spacing: 16) {
                        if let appIcon = appIconImage() {
                            Image(nsImage: appIcon)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                        } else {
                            Image(systemName: "waveform.circle.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(.blue)
                        }

                        Text("DeBrief Version 1.1.0")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Automated meeting intelligence for sales teams.\nCapture discovery calls, generate AI summaries, and sync action items directly to your Obsidian vault.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 380)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Text("[Check for Updates]")
                                .fontWeight(.semibold)
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text("[Support]")
                                .fontWeight(.semibold)
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text("[Documentation]")
                                .fontWeight(.semibold)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            Text("Author: Jesper Mol")
                            Text("•")
                            Text("© \(currentYear)")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(.white.opacity(0.5), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 10)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private func appIconImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "DeBrief-Icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: "AppIcon")
    }

    private var currentYear: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: Date())
    }
}
