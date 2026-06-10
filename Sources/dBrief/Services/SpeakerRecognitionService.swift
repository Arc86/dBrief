import Foundation
import OSLog
import dBriefWire

/// App-side coordinator for the speaker-recognition library: owns the in-memory
/// view of the library, performs matching (delegating to the pure
/// `SpeakerRecognizer`), and mediates enrollment/management through
/// `SpeakerLibraryStore`. Observed by the settings management UI.
@MainActor
@Observable
final class SpeakerRecognitionService {
    private let store = SpeakerLibraryStore()
    private let appSettings: AppSettings

    /// Current library snapshot for UI. Kept in sync after every mutation.
    private(set) var library = SpeakerLibrary()

    init(appSettings: AppSettings) {
        self.appSettings = appSettings
        Task { await reload() }
    }

    func reload() async {
        library = await store.load()
    }

    /// Map detected `speakerId`s to known people's names by voiceprint match,
    /// using the user's similarity threshold. Empty when recognition is off or
    /// the library is empty.
    func recognizedNames(for turns: [DiarizedTurn]) -> [String: String] {
        guard appSettings.speakerRecognitionEnabled, !library.speakers.isEmpty else { return [:] }
        let known = library.speakers.compactMap(\.knownVoice)
        let matches = SpeakerRecognizer.match(
            turns: turns,
            known: known,
            threshold: Float(appSettings.speakerMatchThreshold)
        )
        return matches.mapValues(\.name)
    }

    // MARK: - Enrollment / management

    /// Enroll `name` using the centroid embedding of `speakerId` from `turns`
    /// (the in-memory diarization pass). No-op if that speaker has no embedding.
    func enroll(speakerId: String, name: String, from turns: [DiarizedTurn]) async {
        let centroids = SpeakerRecognizer.speakerCentroids(from: turns)
        guard let embedding = centroids[speakerId], !embedding.isEmpty else {
            Logger.localAI.warning("Speaker enroll: no embedding for \(speakerId, privacy: .public)")
            return
        }
        if let updated = try? await store.enroll(name: name, embedding: embedding) {
            library = updated
        }
    }

    /// Whether a usable embedding exists for `speakerId` in `turns` (drives the
    /// "Remember this person" affordance).
    func hasEmbedding(for speakerId: String, in turns: [DiarizedTurn]) -> Bool {
        guard let emb = SpeakerRecognizer.speakerCentroids(from: turns)[speakerId] else { return false }
        return !emb.isEmpty
    }

    func rename(id: UUID, to newName: String) async {
        if let updated = try? await store.rename(id: id, to: newName) { library = updated }
    }

    func delete(id: UUID) async {
        if let updated = try? await store.delete(id: id) { library = updated }
    }

    func forgetAll() async {
        try? await store.forgetAll()
        await reload()
    }
}
