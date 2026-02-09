import AppKit
import SwiftUI

// 1. HELPER: Grabs the window immediately to fix the "Opening Glitch"
struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.callback(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SettingsView: View {
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
                Label(tab.rawValue, systemImage: tab.icon).tag(tab)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                    .ignoresSafeArea()
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            ZStack {
                // Glass Background
                VisualEffectView(material: .windowBackground, blendingMode: .behindWindow)
                    .ignoresSafeArea()

                // Content
                if let tab = selectedTab {
                    Group {
                        switch tab {
                        case .general: SettingsGeneralTab()
                        case .permissions: SettingsPermissionsTab()
                        case .transcription: SettingsTranscriptionTab()
                        case .ai: SettingsAITab()
                        case .integrations: SettingsIntegrationsTab()
                        case .about: AboutTab()
                        }
                    }
                } else {
                    SettingsGeneralTab()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(WindowAccessor { window in
            configureWindow(window)
        })
        .onAppear {
            if selectedTab == nil {
                selectedTab = .general
            }
            configureWindow(NSApp.keyWindow ?? NSApp.windows.first)
        }
    }

    private func configureWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert([.fullSizeContentView, .titled, .closable, .miniaturizable, .resizable])
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.toolbar = nil
    }
}
