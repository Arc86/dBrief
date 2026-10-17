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
        selectSpeaker(items[min(max(current + offset, 0), items.count - 1)].id)
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
        if let next = ordered.first(where: { !reviewedIDs.contains($0.id) }) {
            selectedID = next.id
        }
    }
}
