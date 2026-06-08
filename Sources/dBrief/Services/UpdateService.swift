import AppKit
import Foundation
import os

private let log = Logger.app

/// Notify-only update checker. Queries the GitHub Releases API for the latest published
/// release, compares it against the running app version, and surfaces whether a newer
/// version is available. Does not download or install — `openReleasePage()` sends the user
/// to the GitHub release page for a manual download.
///
/// All GitHub/version specifics are isolated here so a future Sparkle migration only
/// touches this file.
@MainActor
@Observable
final class UpdateService {
    private(set) var isChecking = false
    private(set) var updateAvailable = false
    private(set) var latestVersion: String?   // normalized, e.g. "1.2.0"
    private(set) var releaseURL: URL?          // html_url of the latest release
    private(set) var lastError: String?

    private let owner = "Arc86"
    private let repo = "dBrief"

    private var apiURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    }

    /// HTML page to fall back to if no specific release URL is known.
    private var repoReleasesURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    }

    /// The running app's short version string (e.g. "1.1.0").
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let name: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case name
        }
    }

    /// Check GitHub for a newer release.
    /// - Parameter manual: when `true`, errors are surfaced via `lastError`; when `false`
    ///   (silent launch check) network/server errors are logged only.
    func checkForUpdates(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                if manual { lastError = "Invalid response from update server." }
                return
            }

            // No releases published yet — treat as "up to date", not an error.
            if http.statusCode == 404 {
                log.info("Update check: no releases published (404).")
                updateAvailable = false
                return
            }

            guard (200...299).contains(http.statusCode) else {
                log.error("Update check failed: HTTP \(http.statusCode)")
                if manual { lastError = "Update check failed (HTTP \(http.statusCode))." }
                return
            }

            let decoder = JSONDecoder()
            let release = try decoder.decode(GitHubRelease.self, from: data)

            let normalized = Self.normalize(release.tagName)
            latestVersion = normalized
            releaseURL = URL(string: release.htmlURL)
            updateAvailable = Self.isNewer(normalized, than: currentVersion)
            log.info("Update check: latest=\(normalized, privacy: .public) current=\(self.currentVersion, privacy: .public) available=\(self.updateAvailable)")
        } catch {
            log.error("Update check error: \(error.localizedDescription, privacy: .public)")
            if manual { lastError = "Could not check for updates: \(error.localizedDescription)" }
        }
    }

    /// Open the release page (or the repo's latest-release page) in the default browser.
    func openReleasePage() {
        NSWorkspace.shared.open(releaseURL ?? repoReleasesURL)
    }

    // MARK: - Version helpers

    /// Strip a leading "v"/"V" from a tag name.
    static func normalize(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first == "v" || first == "V" {
            s.removeFirst()
        }
        return s
    }

    /// Numeric, component-wise semver comparison. Missing components are treated as 0,
    /// and non-numeric components compare as 0 (e.g. pre-release suffixes are ignored).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate)
        let b = components(current)
        let count = max(a.count, b.count)
        for i in 0..<count {
            let lhs = i < a.count ? a[i] : 0
            let rhs = i < b.count ? b[i] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        // Drop any pre-release/build suffix after "-" or "+", then split on ".".
        let core = version.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? version
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
}
