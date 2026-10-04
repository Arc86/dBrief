import Foundation
import IOKit.ps
import UserNotifications
import os

private let log = Logger.app

@MainActor
@Observable
final class PowerStateMonitor {
    private var source: CFRunLoopSource?
    private var lastNotifiedCount: Int = 0
    private var refreshGeneration = 0
    @ObservationIgnored private var callbackBox: Unmanaged<WeakMonitor>?
    private weak var appState: AppState?
    private weak var recordingManager: RecordingManager?

    init(appState: AppState, recordingManager: RecordingManager) {
        self.appState = appState
        self.recordingManager = recordingManager
    }

    func startMonitoring() {
        // The run-loop source outlives nothing it can see, so hand it a retained
        // weak box rather than `self`: a notification after this monitor is gone
        // finds `nil` instead of freed memory. Released in `stopMonitoring`.
        let box = Unmanaged.passRetained(WeakMonitor(self))
        callbackBox = box
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context,
                  let monitor = Unmanaged<WeakMonitor>.fromOpaque(context).takeUnretainedValue().monitor
            else { return }
            Task { @MainActor in
                await monitor.handlePowerChange()
            }
        }, box.toOpaque()).takeRetainedValue()

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        log.info("Power state monitoring started")
    }

    func stopMonitoring() {
        refreshGeneration += 1
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        source = nil
        callbackBox?.release()
        callbackBox = nil
        log.info("Power state monitoring stopped")
    }

    private func handlePowerChange() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        guard isOnACPower() else {
            lastNotifiedCount = 0
            return
        }
        guard let appState, let recordingManager else { return }

        await recordingManager.refreshQueuedCount()
        guard generation == refreshGeneration, isOnACPower(), recordingManager.queueLoadError == nil else { return }
        let count = appState.queuedCount

        guard count > 0, count != lastNotifiedCount else { return }
        lastNotifiedCount = count

        log.info("On AC power with \(count) queued recording(s), sending nudge notification")

        let content = UNMutableNotificationContent()
        content.title = "Recordings Queued"
        content.body = "You have \(count) recording\(count == 1 ? "" : "s") queued for processing. You're now on AC power."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "queue-power-nudge",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    nonisolated private func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              !sources.isEmpty else {
            return true // Desktop Mac, always on AC
        }
        for source in sources {
            if let info = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
               let powerSource = info[kIOPSPowerSourceStateKey] as? String,
               powerSource == kIOPSACPowerValue {
                return true
            }
        }
        return false
    }
}

/// Context for the IOPS callback, which may fire after its monitor is released.
private final class WeakMonitor: @unchecked Sendable {
    weak var monitor: PowerStateMonitor?
    init(_ monitor: PowerStateMonitor) { self.monitor = monitor }
}
