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
    var search = ""
    var manualName = ""

    init(items: [SpeakerReviewItem]) {
        self.items = items
        selectedID = items.first?.id
        edits = Dictionary(items.map { ($0.id, ConfirmedSpeaker(name: $0.proposedName, personId: $0.personId)) },
                           uniquingKeysWith: { first, _ in first })
    }

    var selectedItem: SpeakerReviewItem? { items.first { $0.id == selectedID } }
    var trimmedManualName: String { manualName.trimmingCharacters(in: .whitespacesAndNewlines) }

    func selectSpeaker(_ id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        selectedID = id
        clearInput()
    }

    func clearInput() {
        search = ""
        manualName = ""
    }

    func assign(_ choice: SpeakerReviewCandidates.Choice) {
        guard let selectedItem else { return }
        edits[selectedItem.id] = ConfirmedSpeaker(name: choice.name, personId: choice.personId)
        reviewedIDs.insert(selectedItem.id)
        clearInput()
    }

    func useManualName() {
        let name = trimmedManualName
        guard !name.isEmpty, let selectedItem else { return }
        // A manually corrected label must not keep the suggested person's identity.
        edits[selectedItem.id] = ConfirmedSpeaker(name: name, personId: nil)
        reviewedIDs.insert(selectedItem.id)
        clearInput()
    }

    func keepUnnamed() {
        guard let selectedItem else { return }
        edits[selectedItem.id] = ConfirmedSpeaker(name: selectedItem.id, personId: nil)
        reviewedIDs.insert(selectedItem.id)
        clearInput()
    }
}
