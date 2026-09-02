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
    let transcriptStore = TranscriptStore()
    let insightsStore = InsightsStore()
    let transcriptChatStore = TranscriptChatStore()
    let chatStore = ChatStore()
    let modelPerformanceStore = ModelPerformanceStore()
    let voiceLibraryStore = VoiceLibraryStore()
    let recordingManager: RecordingManager
    let callDetectionService = CallDetectionService()
    let hotkeyService = GlobalHotkeyService()
    let updaterController = UpdaterController()
    let audioPlayer = AudioPlayer()
    let microsoftAuthService = MicrosoftAuthService()
    let miniPlayer = FloatingMiniPlayerController()
    let memoryMonitor = MemoryPressureMonitor()
    let powerStateMonitor: PowerStateMonitor
    let whisperPrewarmCoordinator: WhisperPrewarmCoordinator
    let watchedFolderService: WatchedFolderService
    private var permissionsChecked = false
    private var retentionSchedulerTask: Task<Void, Never>?

    init() {
        log.info("AppContext init")
        registerFontAwesomeBrands()
        self.recordingManager = RecordingManager(appState: appState, appSettings: appSettings, transcriptStore: transcriptStore, insightsStore: insightsStore, voiceLibraryStore: voiceLibraryStore, modelPerformanceStore: modelPerformanceStore, microsoftAuthService: microsoftAuthService)
        CallDetectedOverlayController.shared.configure(
            appState: appState,
            appSettings: appSettings,
            recordingManager: recordingManager
        )
        SpeakerReviewWindowController.shared.configure(
            appState: appState,
            appSettings: appSettings,
            recordingManager: recordingManager,
            audioPlayer: audioPlayer
        )

        self.whisperPrewarmCoordinator = WhisperPrewarmCoordinator(
            appSettings: appSettings, plugin: recordingManager.localPlugin)

        self.watchedFolderService = WatchedFolderService(
            appSettings: appSettings, recordingManager: recordingManager)

        // Start power state monitoring for queue processing nudge
        self.powerStateMonitor = PowerStateMonitor(appState: appState, recordingManager: recordingManager)
        powerStateMonitor.startMonitoring()

        // Start memory pressure monitoring
        memoryMonitor.startMonitoring()
        memoryMonitor.registerCleanupHandler { [weak recordingManager] in
            await recordingManager?.handleMemoryPressure()
        }
        memoryMonitor.registerPressureHandler { [weak self] level in
            self?.appState.memoryPressureLevel = level
        }

        Task { await self.ensureReady() }
    }

    private func ensureReady() async {
        guard !permissionsChecked else { return }
        permissionsChecked = true
        log.info("Refreshing permission status...")
        await recordingManager.checkPermissions()
        log.info("Permissions — mic: \(self.recordingManager.hasMicrophonePermission), system audio: \(self.recordingManager.hasSystemAudioPermission)")
        await recordingManager.recoverInterruptedSessions()
        callDetectionService.start(appState: appState, appSettings: appSettings, recordingManager: recordingManager)
        recordingManager.requestNotificationPermission()
        miniPlayer.setUp(appState: appState, recordingManager: recordingManager, appSettings: appSettings)
        recordingManager.miniPlayer = miniPlayer

        // Apply dock icon preference
        if appSettings.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        }

        // Register the user-configured global hotkey for record toggle
        hotkeyService.register(hotkey: appSettings.recordHotkey) { [weak self] in
            guard let self else { return }
            self.toggleRecording()
        }

        // Purge recordings/transcripts past their retention window.
        await runRetentionCleanupIfNeeded()
        startRetentionCleanupScheduler()

        whisperPrewarmCoordinator.scheduleLaunchPrewarm()

        // Start the watched-folders poller (self-gates on the master toggle/list).
        watchedFolderService.start()

        log.info("Ready")
    }

    /// Runs the enabled auto-delete sweeps off the main thread. Folder URLs are
    /// resolved here (on the main actor) and the file work hops to a background task.
    private func runRetentionCleanupIfNeeded() async {
        guard appSettings.autoDeleteRecordingsEnabled || appSettings.autoDeleteTranscriptsEnabled else {
            return
        }
        let recordingsFolder = appSettings.effectiveRecordingFolderURL
        let transcriptionFolder = appSettings.effectiveTranscriptionFolderURL
        var combined = RetentionCleanupResult()

        if appSettings.autoDeleteRecordingsEnabled {
            let days = appSettings.autoDeleteRecordingsDays
            let result = await Task.detached(priority: .utility) {
                RetentionCleanup.cleanup(category: .recordings, olderThanDays: days, in: [recordingsFolder])
            }.value
            combined.filesDeleted += result.filesDeleted
            combined.bytesFreed += result.bytesFreed
        }
        if appSettings.autoDeleteTranscriptsEnabled {
            let days = appSettings.autoDeleteTranscriptsDays
            let result = await Task.detached(priority: .utility) {
                RetentionCleanup.cleanup(
                    category: .transcripts,
                    olderThanDays: days,
                    in: [recordingsFolder, transcriptionFolder]
                )
            }.value
            combined.filesDeleted += result.filesDeleted
            combined.bytesFreed += result.bytesFreed
        }

        appSettings.lastRetentionCleanupDate = Date()
        appSettings.lastRetentionCleanupSummary = combined.summary
    }

    /// dBrief commonly runs for weeks without relaunching. Check a few times per
    /// day and execute at most once per 24 hours so enabled retention policies keep
    /// their promise without a restart.
    private func startRetentionCleanupScheduler() {
        retentionSchedulerTask?.cancel()
        retentionSchedulerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(6 * 60 * 60))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                guard RetentionSchedule.isDue(lastRun: self.appSettings.lastRetentionCleanupDate) else {
                    continue
                }
                await self.runRetentionCleanupIfNeeded()
            }
        }
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
    /// Set by DBriefApp so the delegate can flush pending chat saves on quit.
    weak var transcriptChatStore: TranscriptChatStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Release Metal/GPU resources before hard-exiting so WindowServer
        // doesn't inherit orphaned GPU allocations that keep it at high
        // utilization until reboot.
        Task { @MainActor in
            // Close active audio writers first. This makes the recovery tracks
            // readable even if a later shutdown task stalls or is interrupted.
            await self.recordingManager?.prepareForTermination()
            // Flush any debounced chat save so an exchange sent moments
            // before quit survives — the _exit() below skips normal teardown.
            await self.transcriptChatStore?.flushAll()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {
        appDelegate.recordingManager = context.recordingManager
        appDelegate.transcriptChatStore = context.transcriptChatStore
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(context.appState)
                .environment(context.appSettings)
                .environment(context.recordingManager)
                .environment(context.audioPlayer)
                .environment(context.microsoftAuthService)
                .environment(\.calmAppearance, context.appSettings.reduceNeon)
        } label: {
            if context.appState.isRecording || context.appState.isPaused {
                HStack(spacing: 4) {
                    Image(systemName: "record.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.red, .red)
                        .environment(\.symbolVariants, .none)
                    if context.appSettings.showMenuBarRecordingDuration {
                        Text(formatMenuBarDuration(context.appState.recordingDuration))
                            .monospacedDigit()
                            .font(.caption)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(context.appState.isPaused ? "dBrief, paused" : "dBrief, recording")
                .accessibilityValue(context.appSettings.showMenuBarRecordingDuration
                    ? formatMenuBarDuration(context.appState.recordingDuration)
                    : "")
            } else if context.appState.isProcessing {
                if reduceMotion {
                    Image(systemName: "circle.dotted")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("dBrief, processing")
                } else {
                    Image(systemName: "circle.dotted")
                        .symbolRenderingMode(.hierarchical)
                        .symbolEffect(.pulse, options: .repeating)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("dBrief, processing")
                }
            } else if context.appState.queuedCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "waveform")
                        .symbolRenderingMode(.hierarchical)
                    Text("\(context.appState.queuedCount)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("dBrief, \(context.appState.queuedCount) queued")
            } else {
                Image(systemName: "waveform")
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityLabel("dBrief, ready")
            }
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(context)
                .environment(context.appSettings)
                .environment(context.recordingManager)
                .environment(context.microsoftAuthService)
                .environment(context.updaterController)
                .environment(\.calmAppearance, context.appSettings.reduceNeon)
                .frame(minWidth: 800, minHeight: 550)
                .onChange(of: context.appSettings.recordHotkey) { _, newValue in
                    context.hotkeyService.update(hotkey: newValue)
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 950, height: 650)

        Window("Transcripts", id: "transcript") {
            TranscriptBrowserView()
                .environment(context)
                .environment(context.appState)
                .environment(context.appSettings)
                .environment(context.audioPlayer)
                .environment(context.recordingManager)
                .environment(context.transcriptChatStore)
                .environment(\.calmAppearance, context.appSettings.reduceNeon)
        }
        .defaultSize(width: 1100, height: 720)
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

    @State private var showYouTubeInput = false

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
                    } else if appState.hasProcessingResults {
                        Divider()
                        ResultsView()
                    }

                    if appState.isIdle, !appState.hasProcessingResults {
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

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Button {
                                recordingManager.pickFileForTranscription()
                            } label: {
                                Label("Transcribe File...", systemImage: "doc.badge.plus")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!appState.isIdle)

                            Button {
                                showYouTubeInput.toggle()
                            } label: {
                                Label("YouTube URL...", systemImage: "play.rectangle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!appState.isIdle)
                        }

                        if showYouTubeInput && appState.isIdle {
                            YouTubeURLInputView(isVisible: $showYouTubeInput)
                        }
                    }
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
            await recordingManager.refreshQueuedCount()
        }
        .padding(12)
        // Let the window-style popover size to its content rather than forcing a
        // hard pixel width; the ideal/min keep it sensible without fighting the OS.
        .frame(minWidth: 340, idealWidth: 360)
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
        HStack(spacing: 6) {
            BrandStatusDot(color: statusColor, size: 8, pulse: appState.isRecording)
            Text(statusLabel)
                .font(.brandMono(11))
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
