import Foundation

/// Turns an arbitrary AI-produced tag into a valid Obsidian tag (without the leading
/// `#`). Obsidian tag validity is enforced **here, at the write boundary** — not via
/// prompt instructions — so any engine (Apple Intelligence, Gemma, Local CLI, remote)
/// and any prompt can't produce a malformed tag in exported Markdown.
///
/// Obsidian tags allow letters, digits, underscore, hyphen, and forward-slash (for
/// nested tags), are case-insensitive (we lowercase for consistency), and must contain
/// at least one non-numeric character. See the YAML/inline writers in
/// `MarkdownGenerator`, `MarkdownInsightsUpdater`, and `ObsidianFormatter`.
enum ObsidianTag {

    /// Sanitize one raw tag, or `nil` if nothing valid remains.
    static func sanitize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        // Drop any leading '#' the model may have included.
        while s.hasPrefix("#") { s.removeFirst() }

        // Whitespace runs → single hyphen.
        s = s.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)

        // Keep only Obsidian-legal characters (Unicode letters/digits + - _ /).
        s = String(s.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "/" })

        // Collapse runs of separators left behind by stripped characters (a single
        // '/' is kept for nested tags, but accidental runs become one hyphen).
        s = s.replacingOccurrences(of: #"[-_/]{2,}"#, with: "-", options: .regularExpression)

        // Trim leading/trailing separators.
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-_/"))
        guard !s.isEmpty else { return nil }

        // Obsidian requires at least one non-numeric character; require a letter so
        // number-and-separator residue ("123-456") is dropped too.
        guard s.contains(where: { $0.isLetter }) else { return nil }

        return s
    }

    /// Sanitize a list, dropping invalid/empty entries and de-duplicating while
    /// preserving first-seen order.
    static func sanitizeAll(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in raw {
            guard let s = sanitize(tag), seen.insert(s).inserted else { continue }
            out.append(s)
        }
        return out
    }
}
