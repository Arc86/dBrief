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
    /// Shared instance — `SPUStandardUpdaterController` starts a real SPUUpdater,
    /// and a second instance would stack a duplicate first-run permission prompt,
    /// so the App struct's stored-property initializers must never create more
    /// than one (SwiftUI may re-create the App value at any time).
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    /// Mirrors `SPUUpdater.canCheckForUpdates`.
    private(set) var canCheckForUpdates = false

    private init() {
        // Beta/dev bundles have SUFeedURL stripped (STRIP_SU_FEED=1): there is no
        // feed to check, so Sparkle must not start — starting it would still show
        // the once-per-install "check for updates automatically?" prompt that can
        // never succeed. Keep the controller for API symmetry; the manual
        // "Check for Updates" item no-ops via canCheckForUpdates == false.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            return
        }

        // startingUpdater: true → Sparkle starts its scheduler immediately, so the
        // automatic launch / once-per-day checks happen without extra wiring.
        let started = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = started

        canCheckForUpdates = started.updater.canCheckForUpdates
        canCheckObservation = started.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] updater, _ in
            // Sparkle delivers this KVO change on the main thread; assumeIsolated is safe.
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// Sparkle's standard "check for updates" — shows the full update UI.
    /// No-op in beta/dev builds (no feed).
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    /// Whether Sparkle automatically checks on its schedule. Persisted by Sparkle
    /// itself (UserDefaults `SUEnableAutomaticChecks`). Always `false` without a feed.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Date of the last update check, for a "Last checked" caption.
    var lastUpdateCheckDate: Date? {
        controller?.updater.lastUpdateCheckDate
    }
}
