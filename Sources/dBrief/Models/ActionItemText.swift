import Foundation

/// Action items as they should leave dBrief: list markers stripped, and the
/// placeholders models write when there is nothing to do ("No action items
/// identified", "None") dropped, so they never become tasks or reminders.
enum ActionItemText {
    /// Non-empty items with their position in the original list (task
    /// destinations key their progress by that position).
    static func deliverable(_ items: [String]) -> [(index: Int, title: String)] {
        items.enumerated().compactMap { index, item in cleaned(item).map { (index, $0) } }
    }

    static func cleaned(_ item: String) -> String? {
        var text = item.trimmingCharacters(in: .whitespacesAndNewlines)
        // Repeated markers ("- - item") come from a marker added to an already listed item.
        while let marker = text.prefixMatch(of: /(?:[-*+•]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)/) {
            text = String(text[marker.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty, !["-", "*", "•"].contains(text), !isPlaceholder(text) else { return nil }
        return text
    }

    private static func isPlaceholder(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!:;"))
        return normalized.wholeMatch(of: placeholder) != nil
    }

    // "none", "n/a", or "(there were) no (clear) action items (were identified) (in this meeting)".
    nonisolated(unsafe) private static let placeholder = /(?:none|n\/?a|nothing|(?:there (?:are|were|is) )?no(?: (?:clear|specific|explicit|concrete|new|other|further))? (?:action items?|actions?|tasks?|next steps?|follow[- ]?ups?|to-?dos?)(?: (?:were |have been |was )?(?:identified|found|mentioned|noted|discussed|assigned|recorded|defined|agreed))?(?: (?:in|from|during) (?:this|the) (?:meeting|recording|transcript|conversation|discussion|session|call))?)/
}
