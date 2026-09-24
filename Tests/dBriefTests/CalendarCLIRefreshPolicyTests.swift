import Testing
import Foundation
@testable import dBrief

struct CalendarCLIRefreshPolicyTests {
    @Test("Historical day needs one refresh after its end, including an empty snapshot")
    func historicalPostDayRefresh() {
        let window = CalendarCLIServiceTests.makeWindow()
        let now = window.end.addingTimeInterval(86_400)
        #expect(CalendarCLIRefreshPolicy.shouldRefresh(window: window,
            lastSuccessfulRefresh: window.end.addingTimeInterval(-60), now: now,
            freshnessSeconds: 3600, force: false))
        #expect(!CalendarCLIRefreshPolicy.shouldRefresh(window: window,
            lastSuccessfulRefresh: window.end.addingTimeInterval(60), now: now,
            freshnessSeconds: 3600, force: false))
    }

    @Test("Live day respects TTL; Manual only and force are explicit")
    func liveDayAndManual() {
        let now = Date()
        let window = CalendarCLIWindow(start: now.addingTimeInterval(-3600),
            end: now.addingTimeInterval(3600), timeZoneID: "UTC")
        #expect(CalendarCLIRefreshPolicy.shouldRefresh(window: window,
            lastSuccessfulRefresh: nil, now: now, freshnessSeconds: 3600, force: false))
        #expect(!CalendarCLIRefreshPolicy.shouldRefresh(window: window,
            lastSuccessfulRefresh: now.addingTimeInterval(-3599), now: now,
            freshnessSeconds: 3600, force: false))
        #expect(CalendarCLIRefreshPolicy.shouldRefresh(window: window,
            lastSuccessfulRefresh: now.addingTimeInterval(-3600), now: now,
            freshnessSeconds: 3600, force: false))
        #expect(!CalendarCLIRefreshPolicy.shouldRefresh(window: window,
            lastSuccessfulRefresh: nil, now: now, freshnessSeconds: 0, force: false))
        #expect(CalendarCLIRefreshPolicy.shouldRefresh(window: window,
            lastSuccessfulRefresh: now, now: now, freshnessSeconds: 0, force: true))
    }
}
