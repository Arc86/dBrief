import Foundation

/// Builds a one-line roster hint naming the people likely present in a meeting,
/// for injection into AI analysis prompts. Helps the model spell names correctly
/// and attribute statements even when diarization produced only raw speaker IDs.
enum AnalysisRoster {
    /// Returns a hint like `"People likely in this meeting: Alice, Bob, Carol."`,
    /// or `nil` when no usable names are available.
    ///
    /// Dedups case-insensitively (keeping the first-seen spelling and order),
    /// drops blank entries and raw diarization placeholders ("Speaker 1",
    /// "speaker_2").
    static func hint(participants: [String], attendees: [String]) -> String? {
        var seen = Set<String>()
        var names: [String] = []
        for raw in participants + attendees {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !isPlaceholder(name) else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            names.append(name)
        }
        guard !names.isEmpty else { return nil }
        return "People likely in this meeting: \(names.joined(separator: ", "))."
    }

    /// True for raw diarization placeholders like "Speaker 1" / "speaker_2".
    private static func isPlaceholder(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasPrefix("speaker") else { return false }
        let rest = lower.dropFirst("speaker".count)
            .trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
        return rest.isEmpty || Int(rest) != nil
    }
}
