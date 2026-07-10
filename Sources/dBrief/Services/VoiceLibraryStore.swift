import Foundation
import OSLog

/// Result of a library rename. `.collision` means the new name already belongs to
/// a different person — the UI should offer a merge instead of creating a duplicate.
enum RenameOutcome: Equatable {
    case renamed
    case notFound
    case collision(existingId: String)
}

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
        AppSupportPaths.subdirectory("VoiceLibrary")
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
    /// Returns the person id (a stable UUID string), or "" for a blank name.
    @discardableResult
    func upsert(name: String, voiceprint: Voiceprint, maxPerPerson: Int = 5, dedupThreshold: Float = 0.97) -> String {
        let display = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return "" }
        let key = display.lowercased()
        var lib = load()
        if let idx = lib.people.firstIndex(where: { $0.name.lowercased() == key }) {
            if !VoiceEnrollment.isDuplicate(voiceprint.embedding, against: lib.people[idx].voiceprints, threshold: dedupThreshold) {
                lib.people[idx].voiceprints.append(voiceprint)
                if lib.people[idx].voiceprints.count > maxPerPerson {
                    lib.people[idx].voiceprints.removeFirst(lib.people[idx].voiceprints.count - maxPerPerson)
                }
                save(lib)
            }
            return lib.people[idx].id
        } else {
            let person = KnownPerson(id: UUID().uuidString, name: display, voiceprints: [voiceprint])
            lib.people.append(person)
            save(lib)
            return person.id
        }
    }

    /// Renames a person by id, preserving the id. Returns `.collision` (no change)
    /// when the new name already belongs to a different person.
    func rename(id: String, to newName: String) -> RenameOutcome {
        let display = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return .notFound }
        var lib = load()
        guard let idx = lib.people.firstIndex(where: { $0.id == id }) else { return .notFound }
        let key = display.lowercased()
        if let other = lib.people.first(where: { $0.id != id && $0.name.lowercased() == key }) {
            return .collision(existingId: other.id)
        }
        lib.people[idx].name = display
        save(lib)
        return .renamed
    }

    /// Moves the source person's voiceprints into the survivor (deduped, bounded to
    /// `maxPerPerson`, newest kept), then removes the source. No-op for equal ids or
    /// a missing id.
    @discardableResult
    func merge(sourceId: String, into survivorId: String, maxPerPerson: Int = 5, dedupThreshold: Float = 0.97) -> Bool {
        guard sourceId != survivorId else { return false }
        var lib = load()
        guard let si = lib.people.firstIndex(where: { $0.id == sourceId }),
              let di = lib.people.firstIndex(where: { $0.id == survivorId }) else { return false }
        for vp in lib.people[si].voiceprints {
            if !VoiceEnrollment.isDuplicate(vp.embedding, against: lib.people[di].voiceprints, threshold: dedupThreshold) {
                lib.people[di].voiceprints.append(vp)
            }
        }
        if lib.people[di].voiceprints.count > maxPerPerson {
            lib.people[di].voiceprints.removeFirst(lib.people[di].voiceprints.count - maxPerPerson)
        }
        lib.people.remove(at: si)
        save(lib)
        return true
    }

    /// Removes a person entirely.
    @discardableResult
    func delete(id: String) -> Bool {
        var lib = load()
        guard let idx = lib.people.firstIndex(where: { $0.id == id }) else { return false }
        lib.people.remove(at: idx)
        save(lib)
        return true
    }

    /// Removes a single voiceprint (matched by `capturedAt`). If it was the person's
    /// last voiceprint, the person is removed too.
    @discardableResult
    func removeVoiceprint(personId: String, capturedAt: Date) -> Bool {
        var lib = load()
        guard let idx = lib.people.firstIndex(where: { $0.id == personId }) else { return false }
        let before = lib.people[idx].voiceprints.count
        lib.people[idx].voiceprints.removeAll { $0.capturedAt == capturedAt }
        guard lib.people[idx].voiceprints.count != before else { return false }
        if lib.people[idx].voiceprints.isEmpty { lib.people.remove(at: idx) }
        save(lib)
        return true
    }
}
