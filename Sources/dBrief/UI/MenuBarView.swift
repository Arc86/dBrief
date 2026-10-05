import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) var openWindow
    @Environment(\.viewerPalette) private var palette

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager

    @State private var showYouTubeInput = false
    @State private var showQueueManagement = false
    @State private var showRecentRecordings = true

    var body: some View {
        VStack(spacing: 10) {
            if !appSettings.hasCompletedOnboarding {
                OnboardingView()
            } else {
                header

                Divider()

                // The post-recording sheet is a focused, dedicated screen: it
                // replaces the recording controls (no Profile row / Record button),
                // history, queue, and file-transcription affordances — matching the
                // "Recording complete" design frame.
                if appState.showPostRecordingSheet {
                    PostRecordingSheet()
                } else {
                    RecordingControlsView()

                    if appState.isProcessing {
                        Divider()
                        TranscriptionProgressView(onCancel: recordingManager.cancelProcessing)
                    } else if appState.hasProcessingResults, !showQueueManagement {
                        Divider()
                        ResultsView()
                    }

                    Divider()

                    // Primary library entry stays visible independently of list
                    // disclosure, processing progress, and completion results.
                    Button {
                        openWindow(id: "transcript")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label("Transcript viewer", systemImage: "rectangle.split.2x1")
                            .uiFont(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.typographyBordered)
                    .controlSize(.large)
                    .help("Open the transcript viewer")

                    if appState.isIdle, !appState.hasProcessingResults {
                        RecordingHistoryView(expanded: $showRecentRecordings)
                    }

                    Divider()
                    ProcessingQueueView(expanded: $showQueueManagement)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Button {
                                recordingManager.pickFileForTranscription()
                            } label: {
                                Label("Transcribe File...", systemImage: "doc.badge.plus")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.typographyBordered)
                            .controlSize(.small)
                            .disabled(!appState.isIdle)

                            Button {
                                showYouTubeInput.toggle()
                            } label: {
                                Label("YouTube URL...", systemImage: "play.rectangle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.typographyBordered)
                            .controlSize(.small)
                            .disabled(!appState.isIdle)
                        }

                        if showYouTubeInput && appState.isIdle {
                            YouTubeURLInputView(isVisible: $showYouTubeInput)
                        }
                    }
                }


            }
        }
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
        .padding(12)
        // Let the window-style popover size to its content rather than forcing a
        // hard pixel width; the ideal/min keep it sensible without fighting the OS.
        .frame(minWidth: 340, idealWidth: 360)
        .background(palette.canvas.color)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = DBriefAppIcon.image {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "waveform.circle.fill")
                    .uiFont(.title2)
                    .foregroundStyle(.blue)
            }

            Text("dBrief")
                .uiFont(.headline)

            Spacer()

            statusPill

            MenuBarSettingsMenu {
                closeMenuBarExtraWindow()
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            BrandStatusDot(color: statusColor, size: 8, pulse: appState.isRecording)
            Text(statusLabel)
                .uiFont(.brandMono(11))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(statusLabel)")
    }

    private var statusLabel: String {
        if appState.isRecording { return "Recording" }
        if appState.isPaused { return "Paused" }
        if appState.isProcessing { return "Processing" }
        return "Ready"
    }

    private var statusColor: Color {
        if appState.isRecording { return Brand.recording }
        if appState.isPaused { return Brand.paused }
        if appState.isProcessing { return Brand.processing }
        return Brand.ready
    }

    private func closeMenuBarExtraWindow() {
        for window in NSApp.windows where window.level == .statusBar {
            window.orderOut(nil)
        }
    }
}

/// Secondary app controls stay compact even with a larger accessibility font.
struct MenuBarSettingsMenu: View {
    let onSettings: () -> Void

    var body: some View {
        Menu {
            Button("Settings…", action: onSettings)
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit dBrief") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .frame(width: 24, height: 24)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Settings and app controls")
        .help("Settings and app controls")
    }
}
