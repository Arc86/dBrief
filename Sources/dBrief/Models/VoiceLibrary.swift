import Foundation

/// One captured voice embedding for a known person.
struct Voiceprint: Codable, Sendable, Equatable {
    var embedding: [Float]   // 256-dim, L2-normalized (FluidAudio WeSpeaker)
    var model: String        // extractor tag, e.g. "fluidaudio-wespeaker-256"
    var capturedAt: Date
}

/// A known person and their accumulated voiceprints.
struct KnownPerson: Codable, Sendable, Equatable, Identifiable {
    var id: String           // stable opaque key (UUID string); never changes on rename
    var name: String         // display spelling (first seen)
    var company: String?     // nil = "No company"; auto-suggested from calendar, user-editable
    var voiceprints: [Voiceprint]
}

/// The global, on-device voice library. Persisted as a single JSON file under
/// Application Support — never per-recording, never uploaded.
struct VoiceLibrary: Codable, Sendable, Equatable {
    var version: Int = 1
    var people: [KnownPerson] = []

    init(version: Int = 1, people: [KnownPerson] = []) {
        self.version = version
        self.people = people
    }
}
