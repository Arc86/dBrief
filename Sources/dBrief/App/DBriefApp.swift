import AppKit
import SwiftUI
import os

private let log = Logger.app

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
    let memoryMonitor = MemoryPressureMonitor()
    let powerStateMonitor: PowerStateMonitor
    private var permissionsChecked = false

    init() {
        log.info("AppContext init")
        registerFontAwesomeBrands()
        self.recordingManager = RecordingManager(appState: appState, appSettings: appSettings)
        CallDetectedOverlayController.shared.configure(
            appState: appState,
            appSettings: appSettings,
            recordingManager: recordingManager
        )

        // Start power state monitoring for queue processing nudge
        self.powerStateMonitor = PowerStateMonitor(appState: appState, recordingManager: recordingManager)
        powerStateMonitor.startMonitoring()

        // Start memory pressure monitoring
        memoryMonitor.startMonitoring()
        memoryMonitor.registerCleanupHandler { [weak recordingManager] in
            await recordingManager?.handleMemoryPressure()
        }

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

        // Apply dock icon preference
        if appSettings.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        }

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

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by DBriefApp so the delegate can clean up GPU resources on quit.
    weak var recordingManager: RecordingManager?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Release Metal/GPU resources before hard-exiting so WindowServer
        // doesn't inherit orphaned GPU allocations that keep it at high
        // utilization until reboot.
        Task { @MainActor in
            await self.recordingManager?.forceReleaseGPU()
            // Bypasses C++ static destructors (`__cxa_finalize_ranges`) which
            // deadlock in `mlx::core::scheduler::Scheduler::~Scheduler()`.
            _exit(0)
        }
        // Cancel normal termination — the Task above will _exit().
        return .terminateCancel
    }
}

@main
struct DBriefApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var context = AppContext()

    init() {
        appDelegate.recordingManager = context.recordingManager
    }

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
            } else if context.appState.queuedCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "waveform")
                        .symbolRenderingMode(.hierarchical)
                    Text("\(context.appState.queuedCount)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                Image(systemName: "waveform")
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .menuBarExtraStyle(.window)

        WindowGroup(id: "settings") {
            SettingsView()
                .environment(context.appSettings)
                .environment(context.recordingManager)
                .frame(minWidth: 800, minHeight: 550)
        }
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
    @Environment(\.openWindow) var openWindow

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 10) {
            if !appSettings.hasCompletedOnboarding {
                OnboardingView()
            } else {
                header

                Divider()

                RecordingControlsView()

                if appState.showPostRecordingSheet {
                    Divider()
                    PostRecordingSheet()
                } else if appState.isProcessing || appState.hasProcessingResults {
                    Divider()
                    TranscriptionProgressView(onCancel: recordingManager.cancelProcessing)
                } else if showHistory {
                    Divider()
                    RecordingHistoryView()
                }

                if appState.queuedCount > 0, appState.isIdle {
                    Divider()
                    HStack {
                        Label("\(appState.queuedCount) queued", systemImage: "tray.full")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Process Queue") {
                            recordingManager.startProcessingQueue()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.orange)
                    }
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

                HStack(spacing: 10) {
                    Button {
                        closeMenuBarExtraWindow()
                        openWindow(id: "settings")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Text("Settings...")
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                    Spacer()

                    Button("Quit dBrief") {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q", modifiers: .command)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
        .task {
            appState.queuedCount = recordingManager.discoverQueuedItems().count
        }
        .padding(12)
        .frame(width: 300)
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

            Text("dBrief")
                .font(.headline)

            Spacer()

            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusLabel)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }

    private var statusLabel: String {
        if appState.isRecording { return "Recording" }
        if appState.isPaused { return "Paused" }
        if appState.isProcessing { return "Processing" }
        return "Ready"
    }

    private var statusColor: Color {
        if appState.isRecording { return .red }
        if appState.isPaused { return .orange }
        if appState.isProcessing { return .blue }
        return .green
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
