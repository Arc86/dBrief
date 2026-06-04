import Foundation
import Testing
@testable import dBrief

struct CalendarMatcherTests {
    private func event(_ title: String, _ start: String, _ end: String) -> CalendarEvent {
        let f = ISO8601DateFormatter()
        return CalendarEvent(
            title: title,
            attendees: [],
            body: "",
            startDate: f.date(from: start)!,
            endDate: f.date(from: end)!
        )
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @Test
    func picksActiveEventContainingTheReferenceTime() {
        let candidates = [
            event("Morning Standup", "2026-06-04T09:00:00Z", "2026-06-04T09:15:00Z"),
            event("Weekly Sync", "2026-06-04T10:00:00Z", "2026-06-04T11:00:00Z"),
        ]
        let match = CalendarMatcher.selectBestMatch(from: candidates, at: date("2026-06-04T10:30:00Z"))
        #expect(match?.title == "Weekly Sync")
    }

    @Test
    func prefersGreatestOverlapWhenMultipleActive() {
        let candidates = [
            event("Quick Chat", "2026-06-04T10:25:00Z", "2026-06-04T10:35:00Z"),
            event("All Hands", "2026-06-04T10:00:00Z", "2026-06-04T11:00:00Z"),
        ]
        let match = CalendarMatcher.selectBestMatch(from: candidates, at: date("2026-06-04T10:30:00Z"))
        #expect(match?.title == "All Hands")
    }

    @Test
    func fallsBackToNearestStartWithinFifteenMinutes() {
        let candidates = [
            event("Upcoming Review", "2026-06-04T10:40:00Z", "2026-06-04T11:00:00Z"),
        ]
        let match = CalendarMatcher.selectBestMatch(from: candidates, at: date("2026-06-04T10:30:00Z"))
        #expect(match?.title == "Upcoming Review")
    }

    @Test
    func returnsNilWhenNearestStartExceedsFifteenMinutes() {
        let candidates = [
            event("Later Meeting", "2026-06-04T11:00:00Z", "2026-06-04T12:00:00Z"),
        ]
        let match = CalendarMatcher.selectBestMatch(from: candidates, at: date("2026-06-04T10:30:00Z"))
        #expect(match == nil)
    }

    @Test
    func returnsNilForEmptyCandidates() {
        let match = CalendarMatcher.selectBestMatch(from: [], at: date("2026-06-04T10:30:00Z"))
        #expect(match == nil)
    }
}
