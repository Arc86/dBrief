import AppKit
import SwiftUI
import os

private let log = Logger.app

/// Holds all shared app state. Created once at launch, passed via environment.
@MainActor
@Observable
final class AppContext {
    /// The only instance. Services register OS callbacks with unretained `self`
    /// (power-source and Carbon hot-key handlers), so an AppContext must never be
    /// built and then discarded: SwiftUI evaluates a `@State` initial value again
    /// whenever it re-creates the App struct, and the dropped duplicate's callbacks
    /// then fire into freed memory (EXC_BAD_ACCESS in PowerStateMonitor, beta 74).
    static let shared = AppContext()

    @ObservationIgnored lazy var promptEditorWindows = PromptEditorWindowController(context: self)
    let appState = AppState()
    let appSettings = AppSettings()
    let transcriptStore = TranscriptStore()
    let insightsStore = InsightsStore()
    let transcriptChatStore = TranscriptChatStore()
    let chatStore = ChatStore()
    let modelPerformanceStore = ModelPerformanceStore()
    let voiceLibraryStore = VoiceLibraryStore()
    let processingJobStore = ProcessingJobStore()
    let recordingManager: RecordingManager
    let callDetectionService = CallDetectionService()
    let hotkeyService = GlobalHotkeyService()
    let updaterController = UpdaterController.shared
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
        self.recordingManager = RecordingManager(
            appState: appState,
            appSettings: appSettings,
            transcriptStore: transcriptStore,
            insightsStore: insightsStore,
            voiceLibraryStore: voiceLibraryStore,
            modelPerformanceStore: modelPerformanceStore,
            processingJobStore: processingJobStore,
            microsoftAuthService: microsoftAuthService
        )
        self.recordingManager.transcriptChatStore = transcriptChatStore
        self.recordingManager.reprocessingRecoveryReady = false
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
        RecordingActionWindowController.shared.configure(
            appState: appState,
            appSettings: appSettings,
            recordingManager: recordingManager
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
        await recordingManager.recoverReprocessingAttempts()
        if recordingManager.reprocessingRecoveryReady {
            await recordingManager.recoverInterruptedSessions()
            await recordingManager.resumeInterruptedProcessingJob()
        }
        callDetectionService.start(appState: appState, appSettings: appSettings, recordingManager: recordingManager)
        recordingManager.requestNotificationPermission()
        miniPlayer.setUp(appState: appState, recordingManager: recordingManager, appSettings: appSettings)
        recordingManager.miniPlayer = miniPlayer

        // Apply dock icon preference
        if appSettings.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        }
        DBriefAppIcon.installDockIcon()

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
        // An interrupted Phase 5A job may be actively reading an old recording.
        // Defer its age-based sweep until a later scheduler run after processing ends.
        guard !recordingManager.hasActiveProcessingJob else { return }
        let recordingsFolder = appSettings.effectiveRecordingFolderURL
        let transcriptionFolder = appSettings.effectiveTranscriptionFolderURL
        var combined = RetentionCleanupResult()

        do {
            if appSettings.autoDeleteRecordingsEnabled {
                let days = appSettings.autoDeleteRecordingsDays
                let result = try await recordingManager.runRetentionCleanup(category: .recordings, days: days, folders: [recordingsFolder])
                combined.filesDeleted += result.filesDeleted
                combined.bytesFreed += result.bytesFreed
            }
            if appSettings.autoDeleteTranscriptsEnabled {
                let days = appSettings.autoDeleteTranscriptsDays
                let result = try await recordingManager.runRetentionCleanup(category: .transcripts, days: days,
                    folders: [recordingsFolder, transcriptionFolder])
                combined.filesDeleted += result.filesDeleted
                combined.bytesFreed += result.bytesFreed
            }

            appSettings.lastRetentionCleanupDate = Date()
            appSettings.lastRetentionCleanupSummary = combined.summary
        } catch {
            appSettings.lastRetentionCleanupSummary = "Cleanup deferred: recovery data could not be safely cleaned, or recording/processing is active."
        }
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
    weak var promptEditorWindows: PromptEditorWindowController?
    private var isTerminating = false

    /// Open With from Finder, or an audio file dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: RecordingManager.isImportableAudio) else { return }
        Task { @MainActor in
            if !AppContext.shared.recordingManager.importFile(url) { NSSound.beep() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateCancel }
        isTerminating = true
        // Release Metal/GPU resources before hard-exiting so WindowServer
        // doesn't inherit orphaned GPU allocations that keep it at high
        // utilization until reboot.
        Task { @MainActor in
            guard await self.promptEditorWindows?.prepareToQuit() != false else {
                self.isTerminating = false
                return
            }
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
    @State private var context = AppContext.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {
        appDelegate.recordingManager = context.recordingManager
        appDelegate.transcriptChatStore = context.transcriptChatStore
        appDelegate.promptEditorWindows = context.promptEditorWindows
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
                .modifier(AppAppearanceScope(settings: context.appSettings))
        } label: {
            Group {
                if context.appState.isRecording || context.appState.isPaused {
                    HStack(spacing: 4) {
                        // Paused gets its own glyph and colour, so a glance at the menu bar
                        // tells a held recording from a running one.
                        Image(systemName: context.appState.isPaused ? "pause.circle.fill" : "record.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(context.appState.isPaused ? .orange : .red, context.appState.isPaused ? .orange : .red)
                            .environment(\.symbolVariants, .none)
                        if context.appSettings.showMenuBarRecordingDuration {
                            Text(formatMenuBarDuration(context.appState.recordingDuration))
                                .monospacedDigit()
                                .uiFont(.caption)
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
                            .uiFont(.caption2)
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
            // Right-click menu and audio-file drop on the icon.
            .modifier(StatusItemControlsInstaller())
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
                .modifier(AppAppearanceScope(settings: context.appSettings))
                .frame(minWidth: 800, minHeight: 550)
                .onChange(of: context.appSettings.recordHotkey) { _, newValue in
                    context.hotkeyService.update(hotkey: newValue)
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 950, height: 650)
        // Open With / Dock drops go to AppDelegate's import; no window should open for them.
        .handlesExternalEvents(matching: [])

        Window("Transcripts", id: "transcript") {
            TranscriptBrowserView()
                .environment(context)
                .environment(context.appState)
                .environment(context.appSettings)
                .environment(context.audioPlayer)
                .environment(context.recordingManager)
                .environment(context.transcriptChatStore)
                .environment(\.calmAppearance, context.appSettings.reduceNeon)
                .modifier(AppAppearanceScope(settings: context.appSettings))
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: [])
        .commands { RecordingCommands() }
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
