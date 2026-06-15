import Foundation
import Testing
@testable import dBrief

struct CalendarMatcherTests {
    /// Builds an event at fixed clock offsets from a deterministic reference instant.
    private func event(
        _ title: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        attendees: [String] = [],
        allDay: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            title: title,
            attendees: attendees.map { CalendarEvent.Person(name: $0, email: nil) },
            body: "",
            isAllDay: allDay,
            startDate: base.addingTimeInterval(start),
            endDate: base.addingTimeInterval(end)
        )
    }

    private let base = Date(timeIntervalSinceReferenceDate: 0)  // fixed, deterministic
    private func t(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    private let hour: TimeInterval = 3600
    private let minute: TimeInterval = 60

    @Test("Personal time block loses to the real meeting it overlaps")
    func personalBlockLoses() {
        // Recording 10:00–10:35.
        let rs = t(10 * hour)
        let re = t(10 * hour + 35 * minute)
        let meeting = event("Standup", 10 * hour, 10.5 * hour, attendees: ["Alice", "Bob"])
        let block = event("Focus time", 9 * hour, 17 * hour, allDay: true)
        let best = CalendarMatcher.selectBestMatch(
            from: [block, meeting], recordingStart: rs, recordingEnd: re
        )
        #expect(best == meeting)
    }

    @Test("All-day event is penalized below a same-overlap timed event")
    func allDayPenalized() {
        let rs = t(14 * hour)
        let re = t(14 * hour + 30 * minute)
        let timed = event("Review", 14 * hour, 14.5 * hour)
        let allDay = event("Holiday", 14 * hour, 14.5 * hour, allDay: true)
        let best = CalendarMatcher.selectBestMatch(
            from: [allDay, timed], recordingStart: rs, recordingEnd: re
        )
        #expect(best == timed)
    }

    @Test("Among identical windows, the one with attendees wins")
    func attendeeTiebreak() {
        let rs = t(9 * hour)
        let re = t(9.5 * hour)
        let withPeople = event("1:1", 9 * hour, 9.5 * hour, attendees: ["Carol"])
        let solo = event("Hold", 9 * hour, 9.5 * hour)
        let best = CalendarMatcher.selectBestMatch(
            from: [solo, withPeople], recordingStart: rs, recordingEnd: re
        )
        #expect(best == withPeople)
    }

    @Test("Back-to-back overrun favors the meeting active at recording start")
    func containsStartBias() {
        // Recording 10:50–11:10 straddles A (10:00–11:00) and B (11:00–12:00).
        let rs = t(10 * hour + 50 * minute)
        let re = t(11 * hour + 10 * minute)
        let a = event("Meeting A", 10 * hour, 11 * hour, attendees: ["Alice"])
        let b = event("Meeting B", 11 * hour, 12 * hour, attendees: ["Bob"])
        let best = CalendarMatcher.selectBestMatch(
            from: [b, a], recordingStart: rs, recordingEnd: re
        )
        #expect(best == a)
    }

    @Test("Tighter-fitting event ranks ahead of a looser one")
    func tightFitRanking() {
        let rs = t(13 * hour)
        let re = t(13.5 * hour)
        let tight = event("Sync", 13 * hour, 13.5 * hour, attendees: ["A"])
        let loose = event("Workshop", 11 * hour, 15 * hour, attendees: ["A"])
        let ranked = CalendarMatcher.rankedMatches(
            from: [loose, tight], recordingStart: rs, recordingEnd: re
        )
        #expect(ranked.first == tight)
        #expect(ranked.count == 2)
    }

    @Test("Starting-soon fallback matches an event just after recording start")
    func startingSoonFallback() {
        // 2-second recording started 10 min before the meeting; no overlap.
        let rs = t(9 * hour + 50 * minute)
        let re = t(9 * hour + 50 * minute + 2)
        let soon = event("Kickoff", 10 * hour, 11 * hour, attendees: ["A"])
        let best = CalendarMatcher.selectBestMatch(
            from: [soon], recordingStart: rs, recordingEnd: re
        )
        #expect(best == soon)
    }

    @Test("No qualifying events returns nil")
    func noMatch() {
        let rs = t(10 * hour)
        let re = t(10.5 * hour)
        let far = event("Lunch", 13 * hour, 14 * hour)
        let best = CalendarMatcher.selectBestMatch(
            from: [far], recordingStart: rs, recordingEnd: re
        )
        #expect(best == nil)
    }

    @Test("Empty candidate list returns nil")
    func emptyCandidates() {
        let best = CalendarMatcher.selectBestMatch(
            from: [], recordingStart: t(10 * hour), recordingEnd: t(10.5 * hour)
        )
        #expect(best == nil)
    }
}
