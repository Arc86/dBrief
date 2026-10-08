import Foundation

/// Pure presentation/decision helpers for the voice library UI. No I/O, no actor —
/// trivially unit-testable.
enum VoiceLibraryDisplay {
    /// Newest voiceprint capture date, or nil when the person has no prints.
    static func lastSeen(_ person: KnownPerson) -> Date? {
        person.voiceprints.map(\.capturedAt).max()
    }

    /// Oldest voiceprint capture date, or nil when the person has no prints.
    static func firstHeard(_ person: KnownPerson) -> Date? {
        person.voiceprints.map(\.capturedAt).min()
    }

    /// How reliably a person can be recognised, by voiceprint count. The store keeps
    /// at most five per person; three or more cover enough variation to match well.
    enum Strength: Int, Comparable, Sendable {
        case weak = 1, good, strong

        static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .weak: "Weak"
            case .good: "Good"
            case .strong: "Strong"
            }
        }
    }

    static func strength(_ person: KnownPerson) -> Strength {
        switch person.voiceprints.count {
        case ...1: .weak
        case 2: .good
        default: .strong
        }
    }

    /// First letters of the first and last word, uppercased; "?" for a blank name.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        guard let first = words.first?.first else { return "?" }
        guard words.count > 1, let last = words.last?.first else { return first.uppercased() }
        return (String(first) + String(last)).uppercased()
    }

    /// A launch-stable colour slot for an avatar key (`hashValue` is seeded per launch).
    static func avatarIndex(for key: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let sum = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return sum % count
    }

    /// The person the others are merged into: most voiceprints, then most recently
    /// heard, then name.
    static func mergeSurvivor(_ people: [KnownPerson]) -> KnownPerson? {
        people.min { a, b in
            if a.voiceprints.count != b.voiceprints.count { return a.voiceprints.count > b.voiceprints.count }
            let la = lastSeen(a) ?? .distantPast, lb = lastSeen(b) ?? .distantPast
            if la != lb { return la > lb }
            return a.name.lowercased() < b.name.lowercased()
        }
    }

    /// Best cosine similarity between any voiceprint of `a` and any of `b` from the
    /// same extractor; nil when there is no comparable pair.
    static func voiceSimilarity(_ a: KnownPerson, _ b: KnownPerson) -> Float? {
        var best: Float?
        for x in a.voiceprints {
            for y in b.voiceprints where x.model == y.model {
                let s = VoiceMatch.cosineSimilarity(x.embedding, y.embedding)
                best = max(best ?? s, s)
            }
        }
        return best
    }

    /// Similarity of a whole selection: its least-alike pair, so a high value means
    /// every selected person sounds alike. Nil below two people or when a pair can't
    /// be compared.
    static func selectionSimilarity(_ people: [KnownPerson]) -> Float? {
        guard people.count > 1 else { return nil }
        var weakest: Float?
        for i in people.indices {
            for j in people.indices where j > i {
                guard let s = voiceSimilarity(people[i], people[j]) else { return nil }
                weakest = min(weakest ?? s, s)
            }
        }
        return weakest
    }

    /// Above this, the inspector suggests the selection is one person. Well over the
    /// resolver's 0.55 match floor and the ~0.28 different-speaker baseline.
    static let likelySamePersonThreshold: Float = 0.7

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
