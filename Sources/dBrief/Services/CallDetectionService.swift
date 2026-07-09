import AppKit
import CoreAudio
import os

private let log = Logger.callDetection

@MainActor
@Observable
final class CallDetectionService {
    struct CallApp {
        let bundleId: String
        let name: String
        /// Font Awesome brand icon, or nil to use an SF Symbol fallback.
        let brandIcon: FABrandIcon?
        /// SF Symbol fallback when no brand icon is available.
        let sfSymbol: String
    }

    static let knownCallApps: [CallApp] = [
        CallApp(bundleId: "us.zoom.xos", name: "Zoom", brandIcon: nil, sfSymbol: "video.fill"),
        CallApp(bundleId: "com.microsoft.teams", name: "Microsoft Teams (classic)", brandIcon: .microsoft, sfSymbol: ""),
        CallApp(bundleId: "com.microsoft.teams2", name: "Microsoft Teams", brandIcon: .microsoft, sfSymbol: ""),
        CallApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack", brandIcon: .slack, sfSymbol: ""),
        CallApp(bundleId: "com.webex.meetingmanager", name: "Webex", brandIcon: nil, sfSymbol: "video.badge.waveform"),
        CallApp(bundleId: "com.apple.FaceTime", name: "FaceTime", brandIcon: .apple, sfSymbol: ""),
        CallApp(bundleId: "com.google.Chrome.app.kjgfgldnnfobanfaklcjnmoidpaoolgp", name: "Google Meet", brandIcon: .google, sfSymbol: ""),
    ]

    /// Browsers that can host a web call (Google Meet, etc.). Used both to identify a web call
    /// on start and to detect a web call ending via per-process mic input.
    static let knownBrowsers: [(bundleId: String, name: String)] = [
        ("com.google.Chrome", "Chrome"),
        ("com.apple.Safari", "Safari"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.microsoft.edgemac", "Edge"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser", "Brave"),
    ]

    private var workspaceObservers: [NSObjectProtocol] = []
    private weak var appState: AppState?
    private weak var appSettings: AppSettings?
    private weak var recordingManager: RecordingManager?
    private var micMonitor: MicActivityMonitor?
    private var micActive = false

    /// Per-process mic-input monitor used to detect a call *ending* (macOS 14.2+). Boxed as
    /// `AnyObject` so the stored property needs no availability annotation.
    private var callAudioMonitor: AnyObject?
    /// Debounce timers, keyed by bundle id: a brief input drop (mute, device switch) must not
    /// read as a call ending. Only a sustained input-off fires the call-end path.
    private var callEndGraceTasks: [String: Task<Void, Never>] = [:]

    var detectedApps: Set<String> = []

    func start(appState: AppState, appSettings: AppSettings, recordingManager: RecordingManager? = nil) {
        self.appState = appState
        self.appSettings = appSettings
        self.recordingManager = recordingManager

        scanRunningApps()

        let launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            // Extract data from notification on the callback thread to avoid sending Notification across isolation
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleId = app?.bundleIdentifier
            let pid = app?.processIdentifier ?? 0
            Task { @MainActor in
                self.handleAppEvent(bundleId: bundleId, pid: pid, launched: true)
            }
        }

        let terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleId = app?.bundleIdentifier
            Task { @MainActor in
                self.handleAppEvent(bundleId: bundleId, pid: 0, launched: false)
            }
        }

        workspaceObservers = [launchObserver, terminateObserver]

        // Start mic activity monitoring (detects a call starting).
        startMicMonitoring()
        // Start per-process mic-input monitoring (detects a call ending) on supported macOS.
        startCallAudioMonitoring()
    }

    func stop() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        micMonitor?.stop()
        micMonitor = nil
        if #available(macOS 14.2, *) {
            (callAudioMonitor as? CallAudioActivityMonitor)?.stop()
        }
        callAudioMonitor = nil
        for task in callEndGraceTasks.values { task.cancel() }
        callEndGraceTasks.removeAll()
    }

    func startMicMonitoring() {
        micMonitor?.stop()
        micMonitor = MicActivityMonitor { [weak self] isActive in
            Task { @MainActor in
                self?.handleMicActivityChange(isActive: isActive)
            }
        }
        micMonitor?.start()
    }

    private func startCallAudioMonitoring() {
        guard #available(macOS 14.2, *) else { return }
        let monitored = Set(Self.knownCallApps.map(\.bundleId))
            .union(Self.knownBrowsers.map(\.bundleId))
        let monitor = CallAudioActivityMonitor(monitoredBundleIds: monitored) { [weak self] bundleId, isRunningInput in
            Task { @MainActor in
                self?.handleCallAudioInputChange(bundleId: bundleId, isRunningInput: isRunningInput)
            }
        }
        callAudioMonitor = monitor
        monitor.start()
    }

    /// A monitored call app's own mic input changed. Input resuming cancels any pending
    /// call-end; input stopping (sustained past a grace period) means the meeting ended.
    private func handleCallAudioInputChange(bundleId: String, isRunningInput: Bool) {
        if isRunningInput {
            callEndGraceTasks[bundleId]?.cancel()
            callEndGraceTasks[bundleId] = nil
            return
        }

        guard let appState, let appSettings else { return }
        guard appSettings.callDetectionEnabled, appSettings.stopRecordingOnCallEnd != .off else { return }
        guard appState.isRecording || appState.isPaused else { return }

        callEndGraceTasks[bundleId]?.cancel()
        callEndGraceTasks[bundleId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.callEndGraceTasks[bundleId] = nil
            self?.handleCallEnded(bundleId: bundleId)
        }
    }

    /// Apply the user's stop-on-call-end preference for a call that has ended.
    private func handleCallEnded(bundleId: String) {
        guard let appState, let appSettings else { return }

        let outcome = CallEndDecision.decide(
            action: appSettings.stopRecordingOnCallEnd,
            scope: appSettings.callEndScope,
            isCapturing: appState.isRecording || appState.isPaused,
            endedBundleId: bundleId,
            initiatorBundleId: appState.callRecordingBundleId,
            alreadyPrompting: appState.showCallEndedPopup
        )

        switch outcome {
        case .ignore:
            return
        case .stop:
            log.info("Call ended (\(bundleId, privacy: .public)) — auto-stopping recording")
            appState.callRecordingBundleId = nil
            Task { await recordingManager?.stopRecording() }
        case .prompt:
            log.info("Call ended (\(bundleId, privacy: .public)) — prompting to stop")
            appState.callEndedApp = Self.displayName(forBundleId: bundleId)
            appState.showCallEndedPopup = true
        }
    }

    /// Human-readable name for a known call app or browser bundle id.
    private static func displayName(forBundleId bundleId: String) -> String {
        if let app = knownCallApps.first(where: { $0.bundleId == bundleId }) {
            return app.name
        }
        if let browser = knownBrowsers.first(where: { $0.bundleId == bundleId }) {
            return "Web call (\(browser.name))"
        }
        return "Call"
    }

    private func handleMicActivityChange(isActive: Bool) {
        micActive = isActive
        // Only mic *activation* is used here (to detect a call starting). Mic *deactivation*
        // can't detect a call ending: dBrief holds the microphone open for the whole recording,
        // so the aggregate default-input device never goes idle mid-recording. Call-end is
        // detected per-process instead (see startCallAudioMonitoring / CallAudioActivityMonitor).
        guard isActive else { return }
        guard let appState, let appSettings else { return }
        guard appSettings.callDetectionEnabled else { return }
        guard appState.isIdle else { return }

        // Don't prompt if we already showed a prompt recently
        guard !appState.showCallDetectedPopup else { return }

        log.info("Microphone activity detected — possible call in progress")

        // Only prompt when a known call app (or frontmost browser) is active.
        guard let matchedApp = identifyActiveCallApp() else { return }

        let appName = matchedApp.name
        let bundleId = matchedApp.bundleId

        if appSettings.disabledCallApps.contains(bundleId) {
            return
        }

        if appSettings.autoRecordCalls {
            log.info("Auto-starting recording for mic activity (\(appName, privacy: .public))")
            Task {
                try? await recordingManager?.startRecording(associatedApp: appName, callBundleId: bundleId)
            }
        } else {
            appState.detectedCallApp = appName
            appState.detectedCallAppBundleId = bundleId
            appState.showCallDetectedPopup = true
        }
    }

    /// Identify the frontmost call app (or browser) when the mic becomes active.
    private func identifyActiveCallApp() -> (name: String, bundleId: String)? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontmost.bundleIdentifier
        else { return nil }

        if let match = Self.knownCallApps.first(where: { $0.bundleId == bundleId }) {
            return (match.name, match.bundleId)
        }

        if let browser = Self.knownBrowsers.first(where: { $0.bundleId == bundleId }) {
            return ("Web call (\(browser.name))", bundleId)
        }

        return nil
    }

    private func scanRunningApps() {
        let running = NSWorkspace.shared.runningApplications
        for app in running {
            guard let bundleId = app.bundleIdentifier else { continue }
            if let match = Self.knownCallApps.first(where: { $0.bundleId == bundleId }) {
                detectedApps.insert(match.name)
            }
        }
    }

    private func handleAppEvent(bundleId: String?, pid: pid_t, launched: Bool) {
        guard let bundleId,
              let match = Self.knownCallApps.first(where: { $0.bundleId == bundleId })
        else { return }

        if launched {
            detectedApps.insert(match.name)
            if micActive {
                promptIfNeeded(appName: match.name, bundleId: bundleId, pid: pid)
            }
        } else {
            detectedApps.remove(match.name)
            // On macOS 14.2+ the per-process mic monitor detects call-end (even while the app
            // stays running); there, app termination is redundant and would double-fire. On
            // older macOS, a quitting call app is the only available call-end signal.
            if #unavailable(macOS 14.2) {
                handleCallEnded(bundleId: bundleId)
            }
        }
    }

    private func promptIfNeeded(appName: String, bundleId: String, pid: pid_t) {
        guard let appSettings, let appState else { return }
        guard appSettings.callDetectionEnabled else { return }
        guard !appSettings.disabledCallApps.contains(bundleId) else { return }
        guard !appSettings.dismissedCallAppPIDs.contains(pid) else { return }
        guard appState.isIdle else { return }
        guard !appState.showCallDetectedPopup else { return }
        guard micActive else { return }

        if appSettings.autoRecordCalls {
            log.info("Auto-starting recording for \(appName, privacy: .public)")
            Task {
                try? await recordingManager?.startRecording(associatedApp: appName, callBundleId: bundleId)
            }
        } else {
            appState.detectedCallApp = appName
            appState.detectedCallAppBundleId = bundleId
            appState.showCallDetectedPopup = true
        }
    }
}

// MARK: - Microphone Activity Monitor

/// Monitors the system default input device to detect when any app starts using the microphone.
/// Uses CoreAudio property listeners — no permissions required for monitoring.
private final class MicActivityMonitor: @unchecked Sendable {
    private let onChange: @Sendable (Bool) -> Void
    private var deviceID: AudioDeviceID = kAudioObjectUnknown
    private var isListening = false
    private var lastReportedState = false
    // CoreAudio removes a listener only when given the *same* block instance
    // that was added — keep it so stop() actually detaches.
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init(onChange: @escaping @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard !isListening else { return }

        deviceID = defaultInputDevice()
        guard deviceID != kAudioObjectUnknown else {
            log.warning("No input device found for mic monitoring")
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.checkMicState()
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)

        if status == noErr {
            listenerBlock = block
            isListening = true
            log.info("Mic activity monitoring started on device \(self.deviceID)")
        } else {
            log.error("Failed to add mic activity listener: \(status)")
        }
    }

    func stop() {
        guard isListening else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        if let block = listenerBlock {
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
            listenerBlock = nil
        }
        isListening = false
    }

    private func checkMicState() {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        guard status == noErr else { return }

        let active = isRunning != 0
        if active != lastReportedState {
            lastReportedState = active
            log.info("Mic activity changed: \(active ? "active" : "inactive")")
            onChange(active)
        }
    }

    private func defaultInputDevice() -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }
}
