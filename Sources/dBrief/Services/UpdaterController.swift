import Foundation
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController`. Owns the updater,
/// mirrors its `canCheckForUpdates` flag into an `@Observable` property so SwiftUI
/// buttons can disable themselves while a check is in flight, and exposes the
/// standard "check now" + auto-check toggle. Sparkle owns all update UI, download,
/// EdDSA verification, and relaunch.
///
/// All Sparkle/feed specifics live here (and in Info.plist's SUFeedURL /
/// SUPublicEDKey), so the rest of the app stays update-mechanism-agnostic.
@MainActor
@Observable
final class UpdaterController {
    private let controller: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?

    /// Mirrors `SPUUpdater.canCheckForUpdates`.
    private(set) var canCheckForUpdates = false

    init() {
        // startingUpdater: true → Sparkle starts its scheduler immediately, so the
        // automatic launch / once-per-day checks happen without extra wiring.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] updater, _ in
            // Sparkle delivers this KVO change on the main thread; assumeIsolated is safe.
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// Sparkle's standard "check for updates" — shows the full update UI.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Whether Sparkle automatically checks on its schedule. Persisted by Sparkle
    /// itself (UserDefaults `SUEnableAutomaticChecks`).
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Date of the last update check, for a "Last checked" caption.
    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }
}
