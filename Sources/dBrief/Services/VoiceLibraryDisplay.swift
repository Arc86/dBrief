import Foundation

/// Pure presentation/decision helpers for the voice library UI. No I/O, no actor —
/// trivially unit-testable.
enum VoiceLibraryDisplay {
    /// Newest voiceprint capture date, or nil when the person has no prints.
    static func lastSeen(_ person: KnownPerson) -> Date? {
        person.voiceprints.map(\.capturedAt).max()
    }

    /// "N voiceprint(s)".
    static func sampleSummary(_ person: KnownPerson) -> String {
        let n = person.voiceprints.count
        return "\(n) voiceprint\(n == 1 ? "" : "s")"
    }

    /// Newest-first; people with no prints sort last; ties broken by case-insensitive name.
    static func sortedByLastSeen(_ people: [KnownPerson]) -> [KnownPerson] {
        people.sorted { a, b in
            switch (lastSeen(a), lastSeen(b)) {
            case let (la?, lb?):
                if la != lb { return la > lb }
                return a.name.lowercased() < b.name.lowercased()
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.name.lowercased() < b.name.lowercased()
            }
        }
    }

    /// Whether the "Save this voice to library" affordance should appear for a turn.
    static func canEnroll(displayName: String, speakerId: String, hasEmbedding: Bool, alreadyEnrolled: Bool) -> Bool {
        guard hasEmbedding, !alreadyEnrolled else { return false }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != speakerId
    }
}
