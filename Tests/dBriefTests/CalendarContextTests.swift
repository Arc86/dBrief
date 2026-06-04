import Foundation
import Testing
@testable import dBrief

struct CalendarContextTests {
    private func makeEvent(body: String) -> CalendarEvent {
        CalendarEvent(
            title: "Weekly Sync",
            attendees: ["Alice", "Bob"],
            body: body,
            startDate: Date(),
            endDate: Date()
        )
    }

    @Test
    func participantsTextJoinsAttendees() {
        let event = makeEvent(body: "")
        #expect(event.participantsText == "Alice, Bob")
    }

    @Test
    func augmentingPrependsContextWhenBodyPresent() {
        let event = makeEvent(body: "Discuss Q2 roadmap and hiring.")
        let augmented = CalendarEvent.augment(prompt: "You are a helpful assistant.", with: event)
        #expect(augmented.contains("Meeting context from calendar:"))
        #expect(augmented.contains("Discuss Q2 roadmap and hiring."))
        #expect(augmented.hasSuffix("You are a helpful assistant."))
    }

    @Test
    func augmentingReturnsBasePromptWhenNoEvent() {
        let augmented = CalendarEvent.augment(prompt: "Base prompt.", with: nil)
        #expect(augmented == "Base prompt.")
    }

    @Test
    func augmentingReturnsBasePromptWhenBodyBlank() {
        let event = makeEvent(body: "   \n  ")
        let augmented = CalendarEvent.augment(prompt: "Base prompt.", with: event)
        #expect(augmented == "Base prompt.")
    }
}
