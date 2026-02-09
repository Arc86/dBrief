import AppKit
import CoreAudio
import os

private let log = Logger(subsystem: "com.dbrief.app", category: "calldetection")

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

    private var workspaceObservers: [NSObjectProtocol] = []
    private weak var appState: AppState?
    private weak var appSettings: AppSettings?
    private weak var recordingManager: RecordingManager?
    private var micMonitor: MicActivityMonitor?
    private var micActive = false

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
        micActive = isActive
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
                try? await recordingManager?.startRecording(associatedApp: appName)
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
