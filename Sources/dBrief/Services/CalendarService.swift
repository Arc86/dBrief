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

    /// Finds the calendar event best matching `date`, or nil if none matches or access is denied.
    func findCurrentEvent(at date: Date) async -> CalendarEvent? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return nil
        }

        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-searchWindow),
            end: date.addingTimeInterval(searchWindow),
            calendars: nil
        )

        let ekEvents = store.events(matching: predicate)
        let candidates = ekEvents.map { Self.makeCalendarEvent(from: $0) }
        return CalendarMatcher.selectBestMatch(from: candidates, at: date)
    }

    /// Maps an EKEvent into our Sendable value type, extracting attendee names + emails,
    /// the organizer, location, and a derived online/onsite signal.
    private static func makeCalendarEvent(from ekEvent: EKEvent) -> CalendarEvent {
        let attendees: [CalendarEvent.Person] = (ekEvent.attendees ?? []).compactMap(makePerson)
        let location = ekEvent.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = ekEvent.notes ?? ""

        // EventKit has no explicit online flag; infer from the URL, location, or notes.
        let onlineHint = [ekEvent.url?.absoluteString, ekEvent.location, notes]
            .compactMap { $0 }
            .joined(separator: " ")
        let isOnline = CalendarEvent.looksOnline(onlineHint) ? true : nil

        return CalendarEvent(
            title: ekEvent.title ?? "",
            attendees: attendees,
            organizer: ekEvent.organizer.flatMap(makePerson),
            body: notes,
            location: (location?.isEmpty == false) ? location : nil,
            isOnline: isOnline,
            startDate: ekEvent.startDate ?? Date(),
            endDate: ekEvent.endDate ?? Date()
        )
    }

    /// Builds a `Person` from an EKParticipant, parsing the `mailto:` email from its URL.
    /// Returns nil when neither a name nor an email is available.
    private static func makePerson(from participant: EKParticipant) -> CalendarEvent.Person? {
        let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scheme = participant.url.scheme?.lowercased()
        let email = scheme == "mailto"
            ? participant.url.absoluteString
                .replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let cleanEmail = (email?.isEmpty == false) ? email : nil
        if name.isEmpty, cleanEmail == nil { return nil }
        return CalendarEvent.Person(name: name.isEmpty ? (cleanEmail ?? "") : name, email: cleanEmail)
    }
}
