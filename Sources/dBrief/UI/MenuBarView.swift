import AppKit
import SwiftUI

/// The menu bar panel ("Signature" design): a status header, flat sections split
/// by hairlines, and a Settings / Quit footer. Colours come from the shared viewer
/// palette, so the panel follows Light, Dark, Paper and Dark Paper.
struct MenuBarView: View {
    @Environment(\.openWindow) var openWindow
    @Environment(\.viewerPalette) private var palette

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager

    @State private var showYouTubeInput = false
    @State private var showQueueManagement = false
    @State private var showRecentRecordings = true
    @State private var contentHeight: CGFloat = 0

    static let panelWidth: CGFloat = 340

    var body: some View {
        Group {
            if !appSettings.hasCompletedOnboarding {
                OnboardingView()
                    .padding(12)
                    .frame(minWidth: 340, idealWidth: Self.panelWidth)
            } else {
                VStack(spacing: 0) {
                    header
                    MenuPanelHairline()
                    boundedContent
                }
                .frame(width: Self.panelWidth)
            }
        }
        .background(palette.surface.color)
        .task {
            await recordingManager.refreshQueuedCount()
        }
        // Keep both section headers visible without making the menu taller than
        // the screen. Opening either list folds the other, but never stops playback.
        .onChange(of: showQueueManagement) { _, expanded in
            if expanded { showRecentRecordings = false }
        }
        .onChange(of: showRecentRecordings) { _, expanded in
            if expanded { showQueueManagement = false }
        }
    }

    // MARK: - Header

    private var status: MenuPanelStatus {
        .resolve(
            isRecording: appState.isRecording,
            isPaused: appState.isPaused,
            isProcessing: appState.isProcessing,
            showsPostRecording: appState.showPostRecordingSheet,
            hasResults: appState.hasProcessingResults
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            BrandBarsMark(height: 20)
            Text("dBrief")
                .uiFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.heading.color)
            // Idle needs no badge, and capture shows its own status beside the timer.
            if status != .ready, status != .recording, status != .paused {
                HStack(spacing: 5) {
                    MenuPanelStatusDot(tone: status.tone, pulse: status == .recording, size: 6)
                    Text(status.label)
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.secondary.color)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Status: \(status.label)")
            }
            Spacer(minLength: 0)
            MenuBarSettingsMenu {
                MenuBarPanel.close()
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Sections

    /// Grows with its content and scrolls only once it would outgrow the screen,
    /// so the header and footer always stay reachable.
    private var boundedContent: some View {
        ScrollView(.vertical) {
            sections
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: MenuPanelContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .scrollBounceBehavior(.basedOnSize)
        .overlayScrollers()
        .frame(height: min(max(contentHeight, 1), maxContentHeight))
        .onPreferenceChange(MenuPanelContentHeightKey.self) { contentHeight = $0 }
    }

    private var maxContentHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(320, screen - 140)
    }

    @ViewBuilder
    private var sections: some View {
        VStack(spacing: 0) {
            // The post-recording sheet is a focused, dedicated screen: it replaces
            // the recording controls, history, queue and import affordances.
            if appState.showPostRecordingSheet {
                MenuPanelSection(showsDivider: false) {
                    PostRecordingSheet()
                }
            } else {
                MenuPanelSection {
                    RecordingControlsView()
                }

                if appState.isProcessing {
                    MenuPanelSection {
                        TranscriptionProgressView(onCancel: recordingManager.cancelProcessing)
                    }
                } else if appState.hasProcessingResults, !showQueueManagement {
                    MenuPanelSection {
                        ResultsView()
                    }
                }

                // Primary library entry stays visible independently of list
                // disclosure, processing progress, and completion results.
                MenuPanelSection(verticalPadding: 10) {
                    Button {
                        MenuBarPanel.open("transcript", with: openWindow)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.stack")
                            Text("Recording library")
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(MenuPanelNeonButtonStyle(height: 32))
                    .help("Open the recording library: every recording with its summary, transcript and assistant")
                }

                if appState.isIdle, !appState.hasProcessingResults {
                    MenuPanelSection {
                        RecordingHistoryView(expanded: $showRecentRecordings)
                    }
                }

                MenuPanelSection {
                    ProcessingQueueView(expanded: $showQueueManagement)
                }

                MenuPanelSection(showsDivider: false) {
                    importRow
                    if showYouTubeInput && appState.isIdle {
                        YouTubeURLInputView(isVisible: $showYouTubeInput)
                    }
                }
            }
        }
    }

    private var importRow: some View {
        HStack(spacing: 8) {
            Button {
                recordingManager.pickFileForTranscription()
            } label: {
                Label("Transcribe file…", systemImage: "doc.badge.plus")
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .secondary, fontSize: 12))
            .disabled(!appState.isIdle)

            Button {
                showYouTubeInput.toggle()
            } label: {
                Label("YouTube URL…", systemImage: "play.rectangle")
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .secondary, fontSize: 12))
            .disabled(!appState.isIdle)
        }
    }

}

/// Settings and Quit, tucked behind a gear in the panel header.
struct MenuBarSettingsMenu: View {
    let onSettings: () -> Void
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        Menu {
            Button("Settings…", action: onSettings)
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit dBrief") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.secondary.color)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Settings and app controls")
        .help("Settings and app controls")
    }
}

private struct MenuPanelContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
