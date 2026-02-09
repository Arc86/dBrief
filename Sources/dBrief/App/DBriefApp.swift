import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.dbrief.app", category: "app")

/// Holds all shared app state. Created once at launch, passed via environment.
@MainActor
@Observable
final class AppContext {
    let appState = AppState()
    let appSettings = AppSettings()
    let recordingManager: RecordingManager
    let callDetectionService = CallDetectionService()
    let hotkeyService = GlobalHotkeyService()
    let audioPlayer = AudioPlayer()
    let miniPlayer = FloatingMiniPlayerController()
    private var permissionsChecked = false

    init() {
        log.info("AppContext init")
        self.recordingManager = RecordingManager(appState: appState, appSettings: appSettings)
        CallDetectedOverlayController.shared.configure(
            appState: appState,
            appSettings: appSettings,
            recordingManager: recordingManager
        )
        Task { await self.ensureReady() }
    }

    private func ensureReady() async {
        guard !permissionsChecked else { return }
        permissionsChecked = true
        log.info("Checking permissions...")
        await recordingManager.checkPermissions()
        log.info("Permissions — mic: \(self.recordingManager.hasMicrophonePermission), system audio: \(self.recordingManager.hasSystemAudioPermission)")
        callDetectionService.start(appState: appState, appSettings: appSettings, recordingManager: recordingManager)
        recordingManager.requestNotificationPermission()
        miniPlayer.setUp(appState: appState, recordingManager: recordingManager)
        recordingManager.miniPlayer = miniPlayer

        // Register global hotkey ⌘⇧R
        hotkeyService.register { [weak self] in
            guard let self else { return }
            self.toggleRecording()
        }

        log.info("Ready")
    }

    private func toggleRecording() {
        if appState.isRecording || appState.isPaused {
            Task { await recordingManager.stopRecording() }
        } else if appState.isIdle {
            Task {
                do {
                    try await recordingManager.startRecording()
                } catch {
                    appState.lastError = error.localizedDescription
                }
            }
        }
    }
}

@main
struct DBriefApp: App {
    @State private var context = AppContext()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(context.appState)
                .environment(context.appSettings)
                .environment(context.recordingManager)
                .environment(context.audioPlayer)
        } label: {
            if context.appState.isRecording || context.appState.isPaused {
                HStack(spacing: 4) {
                    Image(systemName: "record.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.red, .red)
                        .environment(\.symbolVariants, .none)
                    Text(formatMenuBarDuration(context.appState.recordingDuration))
                        .monospacedDigit()
                        .font(.caption)
                }
            } else if context.appState.isProcessing {
                Image(systemName: "circle.dotted")
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.pulse, options: .repeating)
                    .foregroundStyle(.blue)
            } else {
                Image(systemName: "waveform")
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .menuBarExtraStyle(.window)

        // REPLACED: Changed 'Settings' to 'WindowGroup' to allow full custom transparency
        WindowGroup(id: "settings") {
            SettingsView()
                .environment(context.appSettings)
                .frame(minWidth: 800, minHeight: 550)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 950, height: 650)
    }
}

private func formatMenuBarDuration(_ duration: TimeInterval) -> String {
    let total = Int(duration)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

struct MenuBarView: View {
    // ADDED: Environment hook to open the specific window ID
    @Environment(\.openWindow) var openWindow
    
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 12) {
            if !appSettings.hasCompletedOnboarding {
                OnboardingView()
            } else {
                header

                card {
                    RecordingControlsView()
                }

                if appState.showPostRecordingSheet {
                    card { PostRecordingSheet() }
                } else if appState.isProcessing || appState.hasProcessingResults {
                    card { TranscriptionProgressView() }
                } else if showHistory {
                    card { RecordingHistoryView() }
                }

                card {
                    HStack {
                        Button {
                            showHistory.toggle()
                        } label: {
                            Label(showHistory ? "Hide History" : "History", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)

                        Spacer()

                        Button {
                            recordingManager.pickFileForTranscription()
                        } label: {
                            Label("Transcribe File...", systemImage: "doc.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(!appState.isIdle)
                    }
                }

                HStack(spacing: 10) {
                    // UPDATED: Button now opens the specific "settings" WindowGroup
                    Button {
                        closeMenuBarExtraWindow()
                        openWindow(id: "settings")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Text("Settings...")
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    .buttonStyle(.bordered)

                    Button("Quit dBrief") {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q", modifiers: .command)
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = appIconImage() {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("dBrief")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusPill
        }
        .padding(.horizontal, 4)
    }

    private var statusText: String {
        if appState.isRecording { return "Recording in progress" }
        if appState.isPaused { return "Paused" }
        if appState.isProcessing { return "Processing" }
        return "Ready"
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusLabel)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }

    private var statusLabel: String {
        if appState.isRecording { return "REC" }
        if appState.isPaused { return "PAUSED" }
        if appState.isProcessing { return "PROCESSING" }
        return "READY"
    }

    private var statusColor: Color {
        if appState.isRecording { return .red }
        if appState.isPaused { return .orange }
        if appState.isProcessing { return .blue }
        return .green
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }

    private func appIconImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "dBrief-Icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: "AppIcon")
    }

    private func closeMenuBarExtraWindow() {
        for window in NSApp.windows where window.level == .statusBar {
            window.orderOut(nil)
        }
    }
}
