import Foundation
import Testing
@testable import dBrief

struct CalendarLinkPresentationTests {
    private func read(_ outcome: CalendarCLIListOutcome, complete: Bool,
                      entries: [CalendarCLIEntry] = []) -> CalendarCLIListRead {
        CalendarCLIListRead(window: CalendarCLIServiceTests.makeWindow(), entries: entries,
            hasCompleteSnapshot: complete, lastSuccessfulRefresh: complete ? Date() : nil,
            lastAttempt: Date(), outcome: outcome, persistence: nil)
    }

    @Test("Unavailable and partial data do not claim there are no meetings")
    func missingSnapshotMessages() {
        for outcome in [CalendarCLIListOutcome.blocked, .failed, .partial] {
            let list = CalendarLinkMeetingList(recordingStart: Date(), recordingEnd: Date(),
                events: [], cliDays: [read(outcome, complete: false)])
            #expect(list.emptyMessage != "No meetings found for this date.")
            #expect(list.statusMessage != nil)
        }
    }

    @Test("A complete empty snapshot can say no meetings")
    func completeEmptyMessage() {
        let list = CalendarLinkMeetingList(recordingStart: Date(), recordingEnd: Date(),
            events: [], cliDays: [read(.cached, complete: true)])
        #expect(list.emptyMessage == "No meetings found for this date.")
    }

    @Test("Mixed days retain events and show a bounded warning")
    func mixedDayWarning() {
        let entry = CalendarCLICacheTests.entry()
        let list = CalendarLinkMeetingList(recordingStart: Date(), recordingEnd: Date(),
            events: [entry.event], cliDays: [read(.refreshed, complete: true, entries: [entry]),
                                             read(.failed, complete: false)])
        #expect(list.events == [entry.event])
        #expect(list.statusMessage != nil)
        #expect(list.selectionID(for: entry.event) == .cli(entry.key))
    }

    @Test("Occurrence selection survives an attendee-dependent event ID change")
    func stableOccurrenceSelection() {
        let original = CalendarCLICacheTests.entry()
        let withPeople = CalendarCLIEntry(key: original.key,
            event: original.event.replacing(attendees: [.init(name: "Alex", email: "alex@example.com")]),
            sourceRevision: original.sourceRevision, detailsFetchedAt: Date(),
            attendeeState: .loaded, attendeeCount: 1)
        let first = CalendarLinkMeetingList(recordingStart: Date(), recordingEnd: Date(),
            events: [original.event], cliDays: [read(.cached, complete: true, entries: [original])])
        let second = CalendarLinkMeetingList(recordingStart: Date(), recordingEnd: Date(),
            events: [withPeople.event], cliDays: [read(.refreshed, complete: true, entries: [withPeople])])
        #expect(first.selectionID(for: original.event) == second.selectionID(for: withPeople.event))
    }

    @Test("A save failure is visible even when meetings loaded")
    func persistenceFailureStatus() {
        let day = CalendarCLIListRead(window: CalendarCLIServiceTests.makeWindow(), entries: [],
            hasCompleteSnapshot: true, lastSuccessfulRefresh: Date(), lastAttempt: Date(),
            outcome: .refreshed, persistence: .failed)
        let list = CalendarLinkMeetingList(recordingStart: Date(), recordingEnd: Date(),
            events: [], cliDays: [day])
        #expect(list.statusMessage == "Loaded, but could not save the cache.")
    }
}
