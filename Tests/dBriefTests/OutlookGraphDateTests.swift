import Foundation
import Testing
@testable import dBrief

struct OutlookGraphDateTests {
    /// The exact instant Graph encodes as the strings below: 2026-06-04 10:00:00 UTC.
    private var expected: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 4
        c.hour = 10; c.minute = 0; c.second = 0
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test("Parses Graph's 7-digit fractional-second UTC form (the bug we fixed)")
    func parsesSevenDigitFractional() {
        let d = OutlookCalendarService.parseGraphDate("2026-06-04T10:00:00.0000000")
        #expect(d == expected)
    }

    @Test("Parses the plain integer-seconds form")
    func parsesIntegerSeconds() {
        #expect(OutlookCalendarService.parseGraphDate("2026-06-04T10:00:00") == expected)
    }

    @Test("Parses a trailing-Z UTC form")
    func parsesTrailingZ() {
        #expect(OutlookCalendarService.parseGraphDate("2026-06-04T10:00:00Z") == expected)
    }

    @Test("A non-zero fraction still maps to the whole second (sub-second is dropped)")
    func dropsSubSecondPrecision() {
        #expect(OutlookCalendarService.parseGraphDate("2026-06-04T10:00:00.1234567") == expected)
    }

    @Test("nil / empty / malformed input returns nil, never a silent 'now'")
    func returnsNilOnFailure() {
        #expect(OutlookCalendarService.parseGraphDate(nil) == nil)
        #expect(OutlookCalendarService.parseGraphDate("") == nil)
        #expect(OutlookCalendarService.parseGraphDate("not-a-date") == nil)
    }
}
