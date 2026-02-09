import AppKit
import CoreAudio
import os

private let log = Logger(subsystem: "com.dbrief.app", category: "calldetection")

@MainActor
@Observable
final class CallDetectionService {
    static let knownCallApps: [(bundleId: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams (classic)"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.webex.meetingmanager", "Webex"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.google.Chrome.app.kjgfgldnnfobanfaklcjnmoidpaoolgp", "Google Meet"),
    ]

    private var workspaceObservers: [NSObjectProtocol] = []
    private weak var appState: AppState?
    private weak var appSettings: AppSettings?
    private weak var recordingManager: RecordingManager?
    private var micMonitor: MicActivityMonitor?

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

        // Start mic activity monitoring
        startMicMonitoring()
    }

    func stop() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        micMonitor?.stop()
        micMonitor = nil
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

    private func handleMicActivityChange(isActive: Bool) {
        guard isActive else { return }
        guard let appState, let appSettings else { return }
        guard appSettings.callDetectionEnabled else { return }
        guard appState.isIdle else { return }

        // Don't prompt if we already showed a prompt recently
        guard !appState.showCallDetectedPopup else { return }

        log.info("Microphone activity detected — possible call in progress")

        // Try to identify which app is using the mic by checking known call apps
        let matchedApp = identifyActiveCallApp()

        let appName = matchedApp?.name ?? "An app"
        let bundleId = matchedApp?.bundleId ?? "unknown.mic.activity"

        if let bundleId = matchedApp?.bundleId, appSettings.disabledCallApps.contains(bundleId) {
            return
        }

        if appSettings.autoRecordCalls {
            log.info("Auto-starting recording for mic activity (\(appName, privacy: .public))")
            Task {
                try? await recordingManager?.startRecording(associatedApp: appName)
            }
        } else {
            appState.detectedCallApp = matchedApp != nil ? appName : "Microphone active"
            appState.detectedCallAppBundleId = bundleId
            appState.showCallDetectedPopup = true
        }
    }

    /// Try to identify which running app is likely using the mic by checking known call app bundle IDs
    /// and common browser bundle IDs (for web-based calls).
    private func identifyActiveCallApp() -> (name: String, bundleId: String)? {
        let running = NSWorkspace.shared.runningApplications.filter { $0.isActive || !$0.isHidden }

        // First check native call apps
        for app in running {
            guard let bundleId = app.bundleIdentifier else { continue }
            if let match = Self.knownCallApps.first(where: { $0.bundleId == bundleId }) {
                return (match.name, match.bundleId)
            }
        }

        // Check if a browser is the frontmost app (likely a web call)
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontmost.bundleIdentifier {
            let browserBundles: [(id: String, name: String)] = [
                ("com.google.Chrome", "Chrome"),
                ("com.apple.Safari", "Safari"),
                ("company.thebrowser.Browser", "Arc"),
                ("com.microsoft.edgemac", "Edge"),
                ("org.mozilla.firefox", "Firefox"),
                ("com.brave.Browser", "Brave"),
            ]
            if let browser = browserBundles.first(where: { $0.id == bundleId }) {
                return ("Web call (\(browser.name))", bundleId)
            }
        }

        return nil
    }

    private func scanRunningApps() {
        let running = NSWorkspace.shared.runningApplications
        for app in running {
            guard let bundleId = app.bundleIdentifier else { continue }
            if let match = Self.knownCallApps.first(where: { $0.bundleId == bundleId }) {
                detectedApps.insert(match.name)
                promptIfNeeded(appName: match.name, bundleId: bundleId, pid: app.processIdentifier)
            }
        }
    }

    private func handleAppEvent(bundleId: String?, pid: pid_t, launched: Bool) {
        guard let bundleId,
              let match = Self.knownCallApps.first(where: { $0.bundleId == bundleId })
        else { return }

        if launched {
            detectedApps.insert(match.name)
            promptIfNeeded(appName: match.name, bundleId: bundleId, pid: pid)
        } else {
            detectedApps.remove(match.name)
        }
    }

    private func promptIfNeeded(appName: String, bundleId: String, pid: pid_t) {
        guard let appSettings, let appState else { return }
        guard appSettings.callDetectionEnabled else { return }
        guard !appSettings.disabledCallApps.contains(bundleId) else { return }
        guard !appSettings.dismissedCallAppPIDs.contains(pid) else { return }
        guard appState.isIdle else { return }

        if appSettings.autoRecordCalls {
            log.info("Auto-starting recording for \(appName, privacy: .public)")
            Task {
                try? await recordingManager?.startRecording(associatedApp: appName)
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

        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main) { [weak self] _, _ in
            self?.checkMicState()
        }

        if status == noErr {
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

        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main) { [weak self] _, _ in
            self?.checkMicState()
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
