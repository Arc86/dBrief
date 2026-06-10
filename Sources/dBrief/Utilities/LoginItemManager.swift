import Foundation
import ServiceManagement
import dBriefWire
import os

private let log = Logger.app

/// Thin wrapper around `SMAppService.mainApp` for the "Start at login" setting.
///
/// The login-item state lives in the OS (Login Items in System Settings), not in
/// `UserDefaults`, so this reads/writes it directly. Requires the app to run from a
/// proper `.app` bundle (`make app`); it is a no-op when run as a bare SwiftPM
/// executable.
enum LoginItemManager {
    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item. Returns `true` on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            log.error("Failed to \(enabled ? "register" : "unregister") login item: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
