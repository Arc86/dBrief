import Foundation
@preconcurrency import EventKit
import OSLog

/// Reads the user's macOS Calendar via EventKit and finds the event matching a recording's
/// start time. All EventKit access is serialized on this actor; only `CalendarEvent` value
/// types cross the isolation boundary.
actor CalendarService {
    private let store = EKEventStore()

    /// Window queried around the reference date when searching for candidate events.
    private let searchWindow: TimeInterval = 2 * 60 * 60  // ±2 hours

    nonisolated func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Requests full calendar access. Safe to call repeatedly. Returns the granted flag.
    @discardableResult
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            Logger.calendar.error("Calendar access request failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Ranked calendar events plausibly matching the recording span, best-first. Empty if access denied.
    func findCandidates(recordingStart: Date, recordingEnd: Date) async -> [CalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return []
        }

        let predicate = store.predicateForEvents(
            withStart: recordingStart.addingTimeInterval(-searchWindow),
            end: recordingEnd.addingTimeInterval(searchWindow),
            calendars: nil
        )

        let candidates = store.events(matching: predicate).map { Self.makeCalendarEvent(from: $0) }
        return CalendarMatcher.rankedMatches(
            from: candidates, recordingStart: recordingStart, recordingEnd: recordingEnd
        )
    }

    /// Maps an EKEvent into our Sendable value type, extracting attendee display names.
    private static func makeCalendarEvent(from ekEvent: EKEvent) -> CalendarEvent {
        let names: [String] = (ekEvent.attendees ?? []).compactMap { participant in
            let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }
        return CalendarEvent(
            title: ekEvent.title ?? "",
            attendees: names,
            body: ekEvent.notes ?? "",
            startDate: ekEvent.startDate ?? Date(),
            endDate: ekEvent.endDate ?? Date(),
            isAllDay: ekEvent.isAllDay
        )
    }
}
