import Foundation
import Testing
@testable import dBrief

struct CalendarContextTests {
    private func makeEvent(body: String) -> CalendarEvent {
        CalendarEvent(
            title: "Weekly Sync",
            attendees: [
                CalendarEvent.Person(name: "Alice", email: nil),
                CalendarEvent.Person(name: "Bob", email: nil),
            ],
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

    @Test
    func augmentWithRosterPrependsRosterThenAgenda() {
        let event = makeEvent(body: "Discuss Q2 roadmap.")
        let out = CalendarEvent.augment(
            prompt: "BASE",
            with: event,
            roster: "People likely in this meeting: Alice, Bob."
        )
        // roster first, agenda second, base last
        let rosterIdx = out.range(of: "People likely in this meeting: Alice, Bob.")!.lowerBound
        let agendaIdx = out.range(of: "Meeting context from calendar:")!.lowerBound
        let baseIdx = out.range(of: "BASE")!.lowerBound
        #expect(rosterIdx < agendaIdx)
        #expect(agendaIdx < baseIdx)
    }

    @Test
    func augmentWithNilRosterAndNilEventReturnsBaseUnchanged() {
        #expect(CalendarEvent.augment(prompt: "BASE", with: nil, roster: nil) == "BASE")
    }

    @Test
    func augmentWithBlankRosterSkipsRosterLine() {
        let out = CalendarEvent.augment(prompt: "BASE", with: nil, roster: "   ")
        #expect(out == "BASE")
    }
}
