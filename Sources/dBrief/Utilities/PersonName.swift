import Foundation

/// Display-name normalization for people coming from calendars and address books.
///
/// Directory-backed calendars (Exchange/Outlook, and EventKit accounts fed by them) hand us
/// attendee names in `"Last, First"` form — `"den Boer, Bart"`. That comma is not a separator
/// between two people, so it must never be treated as one; this helper turns the pair back
/// into a natural `"Bart den Boer"` before the name reaches participant pills, speaker
/// labels, AI roster hints, or the voice library.
enum PersonName {

    /// Suffixes that legitimately follow a comma but are *not* a given name, so the parts
    /// must not be swapped ("Smith, Jr." is not "Jr. Smith"). Compared lowercased.
    private static let nameSuffixes: Set<String> = [
        "jr", "jr.", "sr", "sr.",
        "i", "ii", "iii", "iv", "v",
        "phd", "ph.d.", "md", "m.d.", "dds", "esq", "esq.",
        "msc", "bsc", "mba", "rn", "cpa",
    ]

    /// Normalizes one raw name: collapses whitespace and flips a single `"Last, First"` pair
    /// into `"First Last"`. Anything else (no comma, several commas, a trailing suffix) keeps
    /// its source order and is only cleaned up. Never returns a name containing a comma, so
    /// callers can't shred it by splitting later.
    static func display(_ raw: String) -> String {
        let parts = raw
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(collapseWhitespace)
            .filter { !$0.isEmpty }

        guard parts.count > 1 else { return parts.first ?? "" }

        if parts.count == 2, !isNameSuffix(parts[1]) {
            return "\(parts[1]) \(parts[0])"
        }
        return parts.joined(separator: " ")
    }

    /// `display` over a list, dropping blanks and de-duping case-insensitively while
    /// preserving first-seen order (which drives diarization's ordinal speaker mapping).
    static func displayList(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in raw {
            let clean = display(name)
            guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { continue }
            out.append(clean)
        }
        return out
    }

    /// Names as typed into a participants field. Here a comma means "and" — someone listing
    /// people types "Alice, Bob" — which is the opposite of the directory convention handled
    /// by `display`, so typed input is split rather than reordered. Blanks dropped, de-duped
    /// case-insensitively, source order preserved.
    static func typedNames(_ raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for part in raw.split(separator: ",") {
            let name = collapseWhitespace(part)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            out.append(name)
        }
        return out
    }

    /// Replaces one entry of a participant list, for editing a single pill in place. Editing
    /// one name is a single-name context (unlike `typedNames`), so `"den Boer, Bart"` typed
    /// here folds into one person. Blank input or an entry that isn't in the list leaves the
    /// list untouched; renaming onto a name another entry already holds merges the two rather
    /// than duplicating. Order is preserved.
    static func replacing(_ oldName: String, in names: [String], with newName: String) -> [String] {
        let clean = display(newName)
        guard !clean.isEmpty,
              let index = names.firstIndex(where: { $0.caseInsensitiveCompare(oldName) == .orderedSame })
        else { return names }

        let collidesElsewhere = names.enumerated().contains { i, existing in
            i != index && existing.caseInsensitiveCompare(clean) == .orderedSame
        }
        var out = names
        if collidesElsewhere {
            out.remove(at: index)
        } else {
            out[index] = clean
        }
        return out
    }

    private static func isNameSuffix(_ part: String) -> Bool {
        nameSuffixes.contains(part.lowercased())
    }

    private static func collapseWhitespace(_ part: Substring) -> String {
        part.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
