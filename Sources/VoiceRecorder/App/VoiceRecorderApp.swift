import SwiftUI
import os

private let log = Logger(subsystem: "com.voicerecorder.app", category: "app")

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
struct VoiceRecorderApp: App {
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
            } else {
                Image(systemName: "waveform")
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(context.appSettings)
        }
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
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 12) {
            if !appSettings.hasCompletedOnboarding {
                OnboardingView()
            } else {
                RecordingControlsView()

                Divider()

                if appState.showPostRecordingSheet {
                    PostRecordingSheet()
                } else if appState.isProcessing {
                    TranscriptionProgressView()
                } else if showHistory {
                    RecordingHistoryView()
                }

                Divider()

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

                Divider()

                SettingsLink {
                    Text("Settings...")
                }
                .keyboardShortcut(",", modifiers: .command)

                Button("Quit DeBrief") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding()
        .frame(width: 300)
        .sheet(isPresented: Binding(
            get: { appState.showCallDetectedPopup },
            set: { appState.showCallDetectedPopup = $0 }
        )) {
            CallDetectedPopup()
                .environment(appState)
                .environment(appSettings)
                .environment(recordingManager)
        }
    }
}
