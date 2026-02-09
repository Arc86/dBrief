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
            .listStyle(.sidebar)
            .listRowSeparator(.hidden)
            .listRowInsets(.init(top: 6, leading: 12, bottom: 6, trailing: 12))
            .scrollContentBackground(.hidden)
            .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                Text(selectedTab.rawValue)
                    .font(.title2.weight(.semibold))

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
                .toggleStyle(.switch)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
            .environment(\.controlSize, .regular)
            .background(VisualEffectView(material: .windowBackground, blendingMode: .behindWindow))
        }
        .ignoresSafeArea()
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
                window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                if #available(macOS 11.0, *) {
                    window.titlebarSeparatorStyle = .none
                }
                window.isOpaque = false
                window.backgroundColor = .clear
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct AboutTab: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    if let appIcon = appIconImage() {
                        Image(nsImage: appIcon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                    } else {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.blue)
                    }

                    Text("dBrief Version 1.1.0")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Automated meeting intelligence for sales teams.\nCapture discovery calls, generate AI summaries, and sync action items directly to your Obsidian vault.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 380)
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
                .frame(maxWidth: .infinity, minHeight: 360)
                .padding(32)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func appIconImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "dBrief-Icon", withExtension: "png"),
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
