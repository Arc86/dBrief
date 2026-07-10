import Foundation

/// Single source of truth for the app's identity-scoped, on-device storage.
///
/// Every persistent store (model cache, voice library, model-performance log,
/// downloaded yt-dlp, Keychain secrets) is namespaced under the running app's
/// **bundle identifier** rather than a hardcoded string. That lets a separate
/// build channel — e.g. a beta shipping `com.dbrief.app.beta` — get its own
/// Application Support folder and Keychain service, so it never collides with the
/// production install's data (and, together with the distinct bundle id, gets its
/// own TCC permission grants).
///
/// When unbundled (`swift run` has no Info.plist, so `bundleIdentifier` is nil)
/// we fall back to `com.dbrief.app`, matching the historical hardcoded path.
enum AppSupportPaths {
    /// The running app's bundle identifier, or the production default when unbundled.
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.dbrief.app"

    /// `~/Library/Application Support/<bundle id>/`
    static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// `~/Library/Application Support/<bundle id>/<component>/`
    static func subdirectory(_ component: String) -> URL {
        base.appendingPathComponent(component, isDirectory: true)
    }
}
