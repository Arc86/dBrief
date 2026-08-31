import Foundation

/// Pure best-match selection for calendar events. No EventKit dependency, fully testable.
enum CalendarMatcher {
    /// Window for the "starting soon" fallback when an event does not overlap the recording.
    static let defaultFallbackWindow: TimeInterval = 15 * 60

    /// Score bonus when the event was active at the moment recording began.
    private static let activeAtStartBonus: Double = 0.10
    /// Score bonus for events that have attendees (real meetings vs. solo blocks).
    private static let hasAttendeesBonus: Double = 0.15
    /// Score multiplier that sinks all-day blocks beneath any timed event.
    private static let allDayPenalty: Double = 0.10

    /// Candidate events that plausibly belong to the recording span `[recordingStart, recordingEnd]`,
    /// ranked best-first. An event qualifies if it overlaps the recording or starts within
    /// ±`fallbackWindow` of the recording start. Scoring favors a tight fit (intersection-over-union),
    /// an event that was active at recording start, and events with attendees; all-day blocks are sunk.
    ///
    /// Matching at recording *stop* (where the true span is known) replaces the old start-instant
    /// heuristic that preferred the longest active event — which let a day-long personal block win
    /// over the short meeting it overlapped.
    static func rankedMatches(
        from candidates: [CalendarEvent],
        recordingStart rs: Date,
        recordingEnd re: Date,
        fallbackWindow: TimeInterval = defaultFallbackWindow
    ) -> [CalendarEvent] {
        let recLen = max(0, re.timeIntervalSince(rs))
        let safeFallbackWindow = max(0, fallbackWindow)

        let scored: [(event: CalendarEvent, score: Double, overlap: Double)] = candidates.compactMap { event in
            let es = event.startDate
            let ee = event.endDate
            let overlap = max(0, min(re, ee).timeIntervalSince(max(rs, es)))
            let qualifies = overlap > 0 || abs(es.timeIntervalSince(rs)) <= safeFallbackWindow
            guard qualifies else { return nil }

            let evLen = max(0, ee.timeIntervalSince(es))
            let union = recLen + evLen - overlap
            var score = union > 0 ? overlap / union : 0          // intersection-over-union
            if es <= rs && rs <= ee { score += activeAtStartBonus }    // active when recording began
            if !event.attendees.isEmpty { score += hasAttendeesBonus } // real meetings have invitees
            if event.isAllDay { score *= allDayPenalty }               // sink personal/all-day blocks
            return (event, score, overlap)
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.overlap != rhs.overlap { return lhs.overlap > rhs.overlap }
            return lhs.event.id < rhs.event.id
        }.map(\.event)
    }

    /// The single best event for the recording span, or nil if none qualifies.
    static func selectBestMatch(
        from candidates: [CalendarEvent],
        recordingStart: Date,
        recordingEnd: Date,
        fallbackWindow: TimeInterval = defaultFallbackWindow
    ) -> CalendarEvent? {
        rankedMatches(
            from: candidates,
            recordingStart: recordingStart,
            recordingEnd: recordingEnd,
            fallbackWindow: fallbackWindow
        ).first
    }

    /// Events displayed by the post-recording Meeting picker. Automatic matches always come
    /// first in their relevance order. When requested, the remaining events overlapping the
    /// recording's local calendar day follow chronologically, with all-day blocks last.
    /// Expanding this list never expands the set eligible for automatic selection.
    static func displayCandidates(
        from candidates: [CalendarEvent],
        automaticMatches: [CalendarEvent],
        recordingStart: Date,
        includeFullRecordingDay: Bool,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [CalendarEvent] {
        var seen = Set<String>()
        let uniqueAutomaticMatches = automaticMatches.filter { seen.insert($0.id).inserted }
        guard includeFullRecordingDay,
              let day = calendar.dateInterval(of: .day, for: recordingStart) else {
            return uniqueAutomaticMatches
        }

        let remaining = candidates
            .filter { event in
                event.endDate > day.start
                    && event.startDate < day.end
                    && seen.insert(event.id).inserted
            }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return !lhs.isAllDay }
                if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
                if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
                return lhs.id < rhs.id
            }

        return uniqueAutomaticMatches + remaining
    }
}
