import Foundation

/// Minimal on-disk contract for an active capture session. Phase 4 will write
/// these manifests atomically; Phase 2 establishes safe discovery behavior.
struct InterruptedSessionManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let fileName = "session.json"

    enum State: String, Codable, Equatable, Sendable {
        case capturing
        case paused
        case finalizing
        case completed
        case discarded

        var isRecoverable: Bool {
            switch self {
            case .capturing, .paused, .finalizing: true
            case .completed, .discarded: false
            }
        }
    }

    struct Track: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Equatable, Sendable {
            case microphone
            case systemAudio
        }

        let kind: Kind
        /// Path relative to the directory containing `session.json`.
        let relativePath: String
    }

    let version: Int
    let id: UUID
    let startedAt: Date
    let state: State
    let tracks: [Track]

    init(
        version: Int = currentVersion,
        id: UUID,
        startedAt: Date,
        state: State,
        tracks: [Track]
    ) {
        self.version = version
        self.id = id
        self.startedAt = startedAt
        self.state = state
        self.tracks = tracks
    }
}

struct InterruptedSessionCandidate: Equatable, Sendable {
    let manifest: InterruptedSessionManifest
    let manifestURL: URL
    let existingTrackURLs: [URL]
}

enum InterruptedSessionDiscovery {
    /// Finds one manifest per immediate session directory. Corrupt, completed,
    /// future-version, empty, and path-traversing sessions are ignored.
    static func discover(
        in sessionsRoot: URL,
        fileManager: FileManager = .default
    ) -> [InterruptedSessionCandidate] {
        guard let sessionDirectories = try? fileManager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var candidates: [InterruptedSessionCandidate] = []

        for sessionDirectory in sessionDirectories {
            let values = try? sessionDirectory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }

            let manifestURL = sessionDirectory.appendingPathComponent(InterruptedSessionManifest.fileName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(InterruptedSessionManifest.self, from: data),
                  manifest.version == InterruptedSessionManifest.currentVersion,
                  manifest.state.isRecoverable
            else { continue }

            let existingTracks = manifest.tracks.compactMap { track in
                safeTrackURL(
                    relativePath: track.relativePath,
                    sessionDirectory: sessionDirectory,
                    fileManager: fileManager
                )
            }
            guard !existingTracks.isEmpty else { continue }

            candidates.append(
                InterruptedSessionCandidate(
                    manifest: manifest,
                    manifestURL: manifestURL,
                    existingTrackURLs: existingTracks
                )
            )
        }

        return candidates.sorted { $0.manifest.startedAt > $1.manifest.startedAt }
    }

    private static func safeTrackURL(
        relativePath: String,
        sessionDirectory: URL,
        fileManager: FileManager
    ) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }

        let resolvedSession = sessionDirectory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = sessionDirectory
            .appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard candidate.path.hasPrefix(resolvedSession.path + "/") else { return nil }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }
        return candidate
    }
}
