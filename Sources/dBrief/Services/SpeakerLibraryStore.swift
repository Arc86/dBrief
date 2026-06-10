import Foundation
import OSLog
import dBriefWire

/// Loads and saves the on-device speaker-recognition library
/// (`speaker-library.json`). Actor + atomic-write pattern mirroring
/// `InsightsStore`/`TranscriptStore`. The file holds biometric voice embeddings,
/// so it is written with restrictive POSIX permissions (`0600` file in a `0700`
/// directory) and never leaves the device.
actor SpeakerLibraryStore {
    private let fileManager = FileManager.default
    private let url: URL

    /// `~/Library/Application Support/com.dbrief.app/speaker-library.json`,
    /// alongside (not inside) the model-cache `LocalAIPlugin` dir.
    static func defaultLibraryURL() -> URL {
        MLHostLocator.supportBase()
            .deletingLastPathComponent() // …/com.dbrief.app/
            .appendingPathComponent("speaker-library.json", isDirectory: false)
    }

    /// - Parameter fileURL: override for the library file (tests). Defaults to
    ///   the on-device Application Support location.
    init(fileURL: URL? = nil) {
        self.url = fileURL ?? Self.defaultLibraryURL()
    }

    /// Returns the saved library, or an empty one when absent/unreadable.
    func load() async -> SpeakerLibrary {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let lib = try? JSONDecoder().decode(SpeakerLibrary.self, from: data)
        else { return SpeakerLibrary() }
        return lib
    }

    func save(_ library: SpeakerLibrary) async throws {
        try ensureSecureDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Enroll an embedding under `name`: append to an existing same-name person
    /// (case-insensitive) or create a new one. Returns the updated library.
    @discardableResult
    func enroll(name: String, embedding: [Float]) async throws -> SpeakerLibrary {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !embedding.isEmpty else { return await load() }
        var lib = await load()
        if let idx = lib.speakers.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            lib.speakers[idx].embeddings.append(embedding)
            if lib.speakers[idx].embeddings.count > KnownSpeaker.maxSamples {
                lib.speakers[idx].embeddings.removeFirst(lib.speakers[idx].embeddings.count - KnownSpeaker.maxSamples)
            }
            lib.speakers[idx].lastSeenAt = Date()
        } else {
            lib.speakers.append(KnownSpeaker(name: trimmed, embeddings: [embedding], lastSeenAt: Date()))
        }
        try await save(lib)
        Logger.localAI.info("Speaker library: enrolled sample for a known speaker (\(lib.speakers.count, privacy: .public) total)")
        return lib
    }

    @discardableResult
    func rename(id: UUID, to newName: String) async throws -> SpeakerLibrary {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        var lib = await load()
        guard !trimmed.isEmpty, let idx = lib.speakers.firstIndex(where: { $0.id == id }) else { return lib }
        lib.speakers[idx].name = trimmed
        try await save(lib)
        return lib
    }

    @discardableResult
    func delete(id: UUID) async throws -> SpeakerLibrary {
        var lib = await load()
        lib.speakers.removeAll { $0.id == id }
        try await save(lib)
        return lib
    }

    /// Forget everyone — deletes the file outright.
    func forgetAll() async throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        Logger.localAI.info("Speaker library: all speakers forgotten")
    }

    // MARK: - Private

    private func ensureSecureDirectory(_ dir: URL) throws {
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } else {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }
}
