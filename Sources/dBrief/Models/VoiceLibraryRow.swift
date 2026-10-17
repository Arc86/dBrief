import Foundation

/// One voice-library table row, flattened from `KnownPerson` with non-optional sort
/// keys (a `KeyPathComparator` needs `Comparable` values). People without a company
/// or voiceprints sort last when ascending.
struct VoiceLibraryRow: Identifiable, Sendable {
    let id: String
    let name: String
    let company: String?
    let voiceprintCount: Int
    let firstHeard: Date?
    let lastHeard: Date?
    let strength: VoiceLibraryDisplay.Strength

    init(_ person: KnownPerson) {
        id = person.id
        name = person.name
        let trimmed = person.company?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        company = trimmed.isEmpty ? nil : trimmed
        voiceprintCount = person.voiceprints.count
        firstHeard = VoiceLibraryDisplay.firstHeard(person)
        lastHeard = VoiceLibraryDisplay.lastSeen(person)
        strength = VoiceLibraryDisplay.strength(person)
    }

    var nameKey: String { name.lowercased() }
    var companyKey: String { company?.lowercased() ?? "\u{FFFF}" }
    var firstHeardKey: Date { firstHeard ?? .distantPast }
    var lastHeardKey: Date { lastHeard ?? .distantPast }
}

extension VoiceLibraryRow {
    enum Column: String, CaseIterable, Identifiable, Sendable {
        case name, company, voiceprints, firstHeard, lastHeard
        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: "Name"
            case .company: "Company"
            case .voiceprints: "Voiceprints"
            case .firstHeard: "First heard"
            case .lastHeard: "Last heard"
            }
        }

        /// The direction a first click on the header sorts in.
        var startsAscending: Bool { self == .name || self == .company }
    }

    /// Stable sort by one column; name then id break ties, always ascending.
    static func sorted(_ rows: [VoiceLibraryRow], by column: Column, ascending: Bool) -> [VoiceLibraryRow] {
        func order<T: Comparable>(_ a: T, _ b: T) -> Bool? {
            a == b ? nil : (ascending ? a < b : a > b)
        }
        return rows.sorted { a, b in
            let primary: Bool? = switch column {
            case .name: order(a.nameKey, b.nameKey)
            case .company: order(a.companyKey, b.companyKey)
            case .voiceprints: order(a.voiceprintCount, b.voiceprintCount)
            case .firstHeard: order(a.firstHeardKey, b.firstHeardKey)
            case .lastHeard: order(a.lastHeardKey, b.lastHeardKey)
            }
            if let primary { return primary }
            return a.nameKey != b.nameKey ? a.nameKey < b.nameKey : a.id < b.id
        }
    }
}

/// Finder-style multi-selection over the rows' on-screen order: click selects one,
/// Command-click toggles, Shift-click selects the range from the anchor.
enum VoiceLibrarySelection {
    static func click(_ id: String, order: [String], current: Set<String>, anchor: String?,
                      command: Bool, shift: Bool) -> (selection: Set<String>, anchor: String?) {
        if shift, let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            return (Set(order[min(from, to)...max(from, to)]), anchor)
        }
        if command {
            var next = current
            if next.remove(id) == nil { next.insert(id) }
            return (next, id)
        }
        return ([id], id)
    }

    /// The row an arrow key lands on: one step from the first (up) or last (down)
    /// selected row, clamped to the list; the first row when nothing is selected.
    static func move(by step: Int, order: [String], current: Set<String>) -> String? {
        guard !order.isEmpty else { return nil }
        let indices = order.indices.filter { current.contains(order[$0]) }
        guard let first = indices.first, let last = indices.last else { return order[0] }
        let target = step < 0 ? first + step : last + step
        return order[min(max(target, 0), order.count - 1)]
    }
}
