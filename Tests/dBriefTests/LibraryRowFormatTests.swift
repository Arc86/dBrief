import Foundation
import Testing
@testable import dBrief

@Suite("Library row date and duration text")
struct LibraryRowFormatTests {
    private static let locale = Locale(identifier: "en_GB")
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        calendar.locale = locale
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Thursday 8 October 2026, 15:30.
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 15, minute: 30))!

    private static func date(_ month: Int, _ day: Int, year: Int = 2026, hour: Int = 10, minute: Int = 15) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func text(_ date: Date) -> String {
        LibraryRowFormat.date(date, now: now, calendar: calendar, locale: locale)
    }

    @Test("Today and yesterday carry the time")
    func recentDays() {
        #expect(Self.text(Self.date(10, 8)) == "Today 10:15")
        #expect(Self.text(Self.date(10, 7, hour: 9, minute: 5)) == "Yesterday 09:05")
    }

    @Test("Earlier this week shows the weekday and time")
    func thisWeek() {
        #expect(Self.text(Self.date(10, 5)) == "Mon 10:15")
    }

    @Test("Older dates omit the year only within the current year")
    func olderDates() {
        // The month abbreviation varies by ICU version ("Sep" / "Sept").
        let thisYear = Self.text(Self.date(9, 23))
        #expect(thisYear.hasPrefix("23 Sep") && !thisYear.contains("2026"))
        let lastYear = Self.text(Self.date(9, 23, year: 2025))
        #expect(lastYear.hasPrefix("23 Sep") && lastYear.hasSuffix("2025"))
    }

    @Test("Durations are compact, and empty when unknown")
    func durations() {
        #expect(LibraryRowFormat.duration(47 * 60, locale: Self.locale) == "47m")
        #expect(LibraryRowFormat.duration(63 * 60, locale: Self.locale) == "1h 3m")
        #expect(LibraryRowFormat.duration(45, locale: Self.locale) == "45s")
        #expect(LibraryRowFormat.duration(0, locale: Self.locale).isEmpty)
        #expect(LibraryRowFormat.duration(.nan, locale: Self.locale).isEmpty)
        #expect(LibraryRowFormat.spokenDuration(47 * 60, locale: Self.locale) == "47 minutes")
    }
}
