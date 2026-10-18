import Testing
@testable import dBrief

@Suite("Deliverable action items")
struct ActionItemTextTests {
    @Test(arguments: [
        "- No action items identified", "No action items identified.", "none", "N/A", "n/a.",
        "There were no action items.", "No clear action items were identified in this meeting",
        "* No actions", "No next steps", "No follow-ups mentioned", "  ", "-", "• None",
    ])
    func placeholdersAreDropped(item: String) {
        #expect(ActionItemText.cleaned(item) == nil)
    }

    @Test(arguments: [
        ("- Send the deck to Max", "Send the deck to Max"),
        ("1. Book the room", "Book the room"),
        ("2) Book the room", "Book the room"),
        ("- [ ] Follow up with Lewis", "Follow up with Lewis"),
        ("• Draft the agenda", "Draft the agenda"),
        ("No-show follow-up with the client", "No-show follow-up with the client"),
        ("None of the slides need changes; send the deck", "None of the slides need changes; send the deck"),
        ("Check that no action items were missed", "Check that no action items were missed"),
    ])
    func realItemsAreKeptWithoutListMarkers(item: String, expected: String) {
        #expect(ActionItemText.cleaned(item) == expected)
    }

    @Test func deliverableKeepsOriginalPositions() {
        let items = ActionItemText.deliverable(["- No action items identified", "Send deck", "", "* Book room"])
        #expect(items.map(\.index) == [1, 3])
        #expect(items.map(\.title) == ["Send deck", "Book room"])
    }
}
