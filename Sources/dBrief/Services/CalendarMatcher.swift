import Foundation

/// Pure best-match selection for calendar events. No EventKit dependency, fully testable.
enum CalendarMatcher {
    /// Window for the "starting soon" fallback when no event is currently active.
    static let fallbackWindow: TimeInterval = 15 * 60  // 15 minutes

    /// Selects the event that best corresponds to `date`.
    /// 1. Among events where startDate <= date <= endDate, pick the greatest overlap with `date`
    ///    (i.e. the longest event still running). 2. Otherwise pick the nearest event whose
    ///    startDate is within ±fallbackWindow of `date`. 3. Otherwise nil.
    static func selectBestMatch(from candidates: [CalendarEvent], at date: Date) -> CalendarEvent? {
        let active = candidates.filter { $0.startDate <= date && date <= $0.endDate }
        if !active.isEmpty {
            return active.max { lhs, rhs in
                lhs.endDate.timeIntervalSince(lhs.startDate) < rhs.endDate.timeIntervalSince(rhs.startDate)
            }
        }

        let upcoming = candidates
            .filter { abs($0.startDate.timeIntervalSince(date)) <= fallbackWindow }
            .min { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }
        return upcoming
    }
}
