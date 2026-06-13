import Foundation

/// A single action item with its owner parsed out of the raw AI string.
///
/// AI engines emit action items in the form `"[WHO] to [TASK] [CONTEXT]"`
/// (see `UnifiedInsightsPrompt`). Rather than regex the `[WHO]` prefix at every
/// render (P-1), we parse it once into this structured value.
struct ParsedActionItem: Identifiable, Hashable, Sendable {
    /// The original, unmodified string. Stable identity and the value persisted
    /// back to the insights sidecar (we never rewrite the on-disk format).
    let raw: String
    /// The owner this instance is grouped under, or `nil` when unassigned.
    let owner: String?
    /// Display text with the leading `[owner] to` stripped, so the owner isn't
    /// repeated under its own group header.
    let text: String

    var id: String { (owner ?? "") + "\u{1F} " + raw }
}

/// All action items for one owner, in first-appearance order.
struct ActionItemGroup: Identifiable {
    /// `nil` owner is surfaced under this label.
    static let unassignedLabel = "Unassigned"

    let owner: String
    let items: [ParsedActionItem]

    var id: String { owner }
    var isUnassigned: Bool { owner == Self.unassignedLabel }
}

/// Pure parsing/grouping of raw action-item strings. Unit-testable, no UI.
enum ActionItemParser {
    /// Matches a leading bracketed owner, e.g. `[Alice]` or `[Alice/Bob]`.
    private static let ownerRegex = try! NSRegularExpression(pattern: #"^\s*\[([^\]]+)\]"#)

    /// Parses one raw string into one entry per owner it names. A shared owner
    /// such as `[Alice/Bob]` (also `,`, `&`, ` and `) yields one entry per person,
    /// so the item appears under each of their groups.
    static func parse(_ raw: String) -> [ParsedActionItem] {
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = ownerRegex.firstMatch(in: raw, range: range),
              let ownerRange = Range(match.range(at: 1), in: raw),
              let fullRange = Range(match.range, in: raw) else {
            return [ParsedActionItem(raw: raw, owner: nil, text: cleaned(raw))]
        }

        let ownerBlob = String(raw[ownerRange])
        var remainder = String(raw[fullRange.upperBound...])
        // Drop a leading "to " that the "[WHO] to [TASK]" template leaves behind.
        let trimmed = remainder.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("to ") {
            remainder = String(trimmed.dropFirst(3))
        } else {
            remainder = trimmed
        }
        let text = cleaned(remainder)

        let owners = splitOwners(ownerBlob)
        guard !owners.isEmpty else {
            return [ParsedActionItem(raw: raw, owner: nil, text: text)]
        }
        return owners.map { ParsedActionItem(raw: raw, owner: $0, text: text) }
    }

    /// Parses and groups a list of raw items by owner, preserving the order in
    /// which owners first appear. Unassigned items are collected into a trailing
    /// "Unassigned" group.
    static func group(_ rawItems: [String]) -> [ActionItemGroup] {
        var order: [String] = []
        var buckets: [String: [ParsedActionItem]] = [:]
        var unassigned: [ParsedActionItem] = []

        for raw in rawItems {
            for item in parse(raw) {
                guard let owner = item.owner else {
                    unassigned.append(item)
                    continue
                }
                if buckets[owner] == nil {
                    buckets[owner] = []
                    order.append(owner)
                }
                buckets[owner]?.append(item)
            }
        }

        var groups = order.map { ActionItemGroup(owner: $0, items: buckets[$0] ?? []) }
        if !unassigned.isEmpty {
            groups.append(ActionItemGroup(owner: ActionItemGroup.unassignedLabel, items: unassigned))
        }
        return groups
    }

    // MARK: - Helpers

    private static func splitOwners(_ blob: String) -> [String] {
        let normalized = blob.replacingOccurrences(of: " and ", with: "/")
        return normalized
            .split(whereSeparator: { $0 == "/" || $0 == "," || $0 == "&" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func cleaned(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a leftover leading bullet/marker if present.
        if let r = t.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
            t = String(t[r.upperBound...])
        }
        return t
    }
}
