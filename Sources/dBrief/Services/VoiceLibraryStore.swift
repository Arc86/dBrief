import Foundation
import OSLog

/// Loads/saves the global voice library at
/// `~/Library/Application Support/com.dbrief.app/VoiceLibrary/library.json`.
/// Mirrors `ModelPerformanceStore`'s actor + best-effort atomic-write pattern.
/// The file lives outside the recording/transcription folders, so
/// `RetentionCleanup` never touches it.
actor VoiceLibraryStore {
    private let fileManager = FileManager.default
    private let url: URL

    init(url: URL = VoiceLibraryStore.defaultURL()) {
        self.url = url
    }

    static func defaultURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("com.dbrief.app", isDirectory: true)
            .appendingPathComponent("VoiceLibrary", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    /// Loads the library, or an empty library when absent/unreadable.
    func load() -> VoiceLibrary {
        guard fileManager.fileExists(atPath: url.path) else { return VoiceLibrary() }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(VoiceLibrary.self, from: data)
        } catch {
            Logger.app.error("VoiceLibraryStore load failed: \(error.localizedDescription, privacy: .public)")
            return VoiceLibrary()
        }
    }

    /// Best-effort atomic save; creates the parent directory if needed.
    func save(_ library: VoiceLibrary) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(library).write(to: url, options: .atomic)
        } catch {
            Logger.app.error("VoiceLibraryStore save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adds a voiceprint to the named person (creating them if new), keeping at
    /// most `maxPerPerson` newest prints. Name match is case-insensitive on the
    /// trimmed name; the first-seen display spelling is preserved. A new print
    /// that is a near-duplicate (cosine ≥ `dedupThreshold`) of one the person
    /// already has is skipped, so the bounded set stays diverse.
    /// Returns the person id (lowercased trimmed name), or "" for a blank name.
    @discardableResult
    func upsert(name: String, voiceprint: Voiceprint, maxPerPerson: Int = 5, dedupThreshold: Float = 0.97) -> String {
        let display = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return "" }
        let key = display.lowercased()
        var lib = load()
        if let idx = lib.people.firstIndex(where: { $0.id == key }) {
            if !VoiceEnrollment.isDuplicate(voiceprint.embedding, against: lib.people[idx].voiceprints, threshold: dedupThreshold) {
                lib.people[idx].voiceprints.append(voiceprint)
                if lib.people[idx].voiceprints.count > maxPerPerson {
                    lib.people[idx].voiceprints.removeFirst(lib.people[idx].voiceprints.count - maxPerPerson)
                }
                save(lib)
            }
        } else {
            lib.people.append(KnownPerson(id: key, name: display, voiceprints: [voiceprint]))
            save(lib)
        }
        return key
    }
}
