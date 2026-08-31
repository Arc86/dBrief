import Testing
@testable import dBrief

struct ICalCalendarFilterTests {
    @Test("Nil selection preserves all-calendars mode")
    func allCalendars() {
        let resolved = ICalCalendarFilter.resolvedIdentifiers(
            available: ["work", "personal"],
            selected: nil
        )

        #expect(resolved == nil)
    }

    @Test("Multiple selected calendars resolve as an allow-list")
    func multipleCalendars() {
        let resolved = ICalCalendarFilter.resolvedIdentifiers(
            available: ["work", "personal", "team"],
            selected: ["work", "team"]
        )

        #expect(resolved == ["work", "team"])
    }

    @Test("Unavailable selections never broaden to all calendars")
    func unavailableCalendars() {
        let resolved = ICalCalendarFilter.resolvedIdentifiers(
            available: ["personal"],
            selected: ["work", "team"]
        )

        #expect(resolved == [])
    }
}
