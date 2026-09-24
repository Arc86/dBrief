import Foundation

enum CalendarCLIRefreshPolicy {
    static func shouldRefresh(window: CalendarCLIWindow, lastSuccessfulRefresh: Date?,
                              now: Date, freshnessSeconds: Int, force: Bool) -> Bool {
        if force { return true }
        if freshnessSeconds == 0 { return false }
        guard let success = lastSuccessfulRefresh else { return true }
        if window.end <= now { return success < window.end }
        return now.timeIntervalSince(success) >= TimeInterval(freshnessSeconds)
    }
}
