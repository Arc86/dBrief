import Foundation

struct InterruptedCaptureSession: Sendable {
    let directoryURL: URL
    let manifestURL: URL
    let captureBaseURL: URL
}

/// Atomic persistence for recordings that have not reached a durable master
/// audio file yet. The store lives in Application Support, never in macOS's
/// purgeable temporary directory.
enum InterruptedSessionStore {
    static var defaultRootURL: URL {
        AppSupportPaths.subdirectory("Recording Recovery")
    }

    static func createSession(
        id: UUID,
        startedAt: Date,
        rootURL: URL = defaultRootURL,
        fileManager: FileManager = .default
    ) throws -> InterruptedCaptureSession {
        let directory = rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let session = InterruptedCaptureSession(
            directoryURL: directory,
            manifestURL: directory.appendingPathComponent(InterruptedSessionManifest.fileName),
            captureBaseURL: directory.appendingPathComponent("capture")
        )

        // List both deterministic track names up front. Discovery ignores files
        // that were never created, while this closes the crash window between
        // starting the audio pipelines and learning which one produced data.
        let manifest = InterruptedSessionManifest(
            id: id,
            startedAt: startedAt,
            state: .capturing,
            tracks: [
                .init(kind: .microphone, relativePath: "capture.mic.caf"),
                .init(kind: .systemAudio, relativePath: "capture.system.caf"),
            ]
        )
        try write(manifest, to: session.manifestURL, fileManager: fileManager)
        return session
    }

    static func write(
        _ manifest: InterruptedSessionManifest,
        to manifestURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    @discardableResult
    static func updateState(
        at manifestURL: URL,
        to state: InterruptedSessionManifest.State,
        fileManager: FileManager = .default
    ) throws -> InterruptedSessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let current = try decoder.decode(
            InterruptedSessionManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let updated = current.updatingState(state)
        try write(updated, to: manifestURL, fileManager: fileManager)
        return updated
    }

    static func removeSession(
        containing manifestURL: URL,
        finalState: InterruptedSessionManifest.State,
        fileManager: FileManager = .default
    ) throws {
        _ = try updateState(at: manifestURL, to: finalState, fileManager: fileManager)
        try fileManager.removeItem(at: manifestURL.deletingLastPathComponent())
    }
}
