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
    private weak var appState: AppState?
    private weak var recordingManager: RecordingManager?

    init(appState: AppState, recordingManager: RecordingManager) {
        self.appState = appState
        self.recordingManager = recordingManager
    }

    func startMonitoring() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerStateMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                monitor.handlePowerChange()
            }
        }, context).takeRetainedValue()

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        log.info("Power state monitoring started")
    }

    func stopMonitoring() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        source = nil
        log.info("Power state monitoring stopped")
    }

    private func handlePowerChange() {
        guard isOnACPower() else {
            lastNotifiedCount = 0
            return
        }
        guard let appState, let recordingManager else { return }

        let count = recordingManager.discoverQueuedItems().count
        appState.queuedCount = count

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
        UNUserNotificationCenter.current().add(request)
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
