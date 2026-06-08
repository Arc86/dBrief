import Foundation

/// The Application Support base the parent app passes via `--support-base`,
/// so the helper resolves the SAME model cache directory as the app
/// (e.g. `~/Library/Application Support/com.dbrief.app/LocalAIPlugin`).
///
/// The app's bundle id differs from the helper's `Bundle.main.bundleIdentifier`,
/// so we never derive this path locally — it is injected at launch.
enum SupportPaths {
    nonisolated(unsafe) static var localAIPluginBase: URL!

    /// `<base>/<component>`, creating intermediate directories.
    static func subdirectory(_ component: String) throws -> URL {
        let dir = localAIPluginBase.appendingPathComponent(component, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
