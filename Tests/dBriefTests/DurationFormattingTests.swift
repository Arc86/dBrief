import Foundation
import Testing
@testable import dBrief

struct DurationFormattingTests {
    @Test func formatsMinutesAndHours() {
        #expect(TimeInterval(65).formattedDuration == "1:05")
        #expect(TimeInterval(4503).formattedDuration == "1:15:03")
    }

    @Test func clampsValuesThatCannotBeTimes() {
        #expect(TimeInterval(-3).formattedDuration == "0:00")
        #expect(TimeInterval.nan.formattedDuration == "0:00")
        #expect(TimeInterval.infinity.formattedDuration == "0:00")
    }
}
