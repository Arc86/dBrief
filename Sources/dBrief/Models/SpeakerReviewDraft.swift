import Foundation
import Observation

/// Local edits stay separate from the held recording until the review is confirmed.
@MainActor
@Observable
final class SpeakerReviewDraft {
    let items: [SpeakerReviewItem]
    var selectedID: String?
    private(set) var edits: [String: ConfirmedSpeaker]
    private(set) var reviewedIDs: Set<String> = []
    /// One field both filters the people list and supplies a new name.
    var search = ""
    /// Speaks what an answer or a voice change did, since the picker is rebuilt silently.
    @ObservationIgnored var announce: @MainActor (String) -> Void = { AccessibilityAnnouncer.shared.announce($0) }

    init(items: [SpeakerReviewItem]) {
        self.items = items
        selectedID = items.first?.id
        edits = Dictionary(items.map { ($0.id, ConfirmedSpeaker(name: $0.proposedName, personId: $0.personId)) },
                           uniquingKeysWith: { first, _ in first })
    }

    var selectedItem: SpeakerReviewItem? { items.first { $0.id == selectedID } }
    var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    var allReviewed: Bool { !items.isEmpty && reviewedIDs.count == items.count }

    func selectSpeaker(_ id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        selectedID = id
        clearInput()
    }

    /// Moves to the previous or next speaker, stopping at either end.
    func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? -1
        let target = min(max(current + offset, 0), items.count - 1)
        guard target != current else { return }
        selectSpeaker(items[target].id)
        announce(String(localized: "\(items[target].id), \(target + 1) of \(items.count)"))
    }

    func clearInput() {
        search = ""
    }

    func assign(_ choice: SpeakerReviewCandidates.Choice) {
        record(ConfirmedSpeaker(name: choice.name, personId: choice.personId))
    }

    /// Uses the typed text as a new name.
    func useTypedName() {
        let name = trimmedSearch
        guard !name.isEmpty else { return }
        // A manually corrected label must not keep the suggested person's identity.
        record(ConfirmedSpeaker(name: name, personId: nil))
    }

    func keepUnnamed() {
        guard let selectedItem else { return }
        record(ConfirmedSpeaker(name: selectedItem.id, personId: nil))
    }

    /// Saves the answer for the selected speaker, then moves on to the next one still unreviewed.
    private func record(_ speaker: ConfirmedSpeaker) {
        guard let selectedItem else { return }
        edits[selectedItem.id] = speaker
        reviewedIDs.insert(selectedItem.id)
        clearInput()
        let index = items.firstIndex { $0.id == selectedItem.id } ?? 0
        let ordered = items[(index + 1)...] + items[..<index]
        let next = ordered.first(where: { !reviewedIDs.contains($0.id) })
        if let next { selectedID = next.id }
        announce(Self.announcement(for: selectedItem.id, answer: speaker, next: next?.id,
                                   left: items.count - reviewedIDs.count))
    }

    /// "Speaker 1 named Alice. Now Speaker 2, 1 voice left." or "… All voices reviewed."
    static func announcement(for speakerID: String, answer: ConfirmedSpeaker, next: String?, left: Int) -> String {
        let unnamed = answer.name == speakerID
        guard let next else {
            return unnamed
                ? String(localized: "\(speakerID) kept unnamed. All voices reviewed. Press Return to confirm.")
                : String(localized: "\(speakerID) named \(answer.name). All voices reviewed. Press Return to confirm.")
        }
        // Inflected so English reads "1 voice" without the catalog (tests); the catalog has the plural variants.
        let text = unnamed
            ? AttributedString(localized: "\(speakerID) kept unnamed. Now \(next), ^[\(left) voice](inflect: true) left.")
            : AttributedString(localized: "\(speakerID) named \(answer.name). Now \(next), ^[\(left) voice](inflect: true) left.")
        return String(text.characters)
    }
}
