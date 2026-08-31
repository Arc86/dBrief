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

    /// Calendar events around the recording, optionally expanded to cover its full local day.
    /// Empty if access is denied. Ranking stays in `CalendarMatcher` so automatic matching and
    /// the broader manual picker remain separate concerns.
    func findEvents(
        recordingStart: Date,
        recordingEnd: Date,
        includeFullRecordingDay: Bool,
        selectedCalendarIDs: Set<String>?
    ) async -> [CalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return []
        }

        let calendars: [EKCalendar]?
        let availableCalendars = store.calendars(for: .event)
        let resolvedCalendarIDs = ICalCalendarFilter.resolvedIdentifiers(
            available: availableCalendars.map(\.calendarIdentifier),
            selected: selectedCalendarIDs
        )
        if let resolvedCalendarIDs {
            guard !resolvedCalendarIDs.isEmpty else { return [] }
            calendars = availableCalendars.filter {
                resolvedCalendarIDs.contains($0.calendarIdentifier)
            }
        } else {
            calendars = nil
        }

        var queryStart = recordingStart.addingTimeInterval(-searchWindow)
        var queryEnd = recordingEnd.addingTimeInterval(searchWindow)
        if includeFullRecordingDay,
           let day = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: recordingStart) {
            queryStart = min(queryStart, day.start)
            queryEnd = max(queryEnd, day.end)
        }

        let predicate = store.predicateForEvents(
            withStart: queryStart,
            end: queryEnd,
            calendars: calendars
        )

        return store.events(matching: predicate).compactMap { Self.makeCalendarEvent(from: $0) }
    }

    /// Maps an EKEvent into our Sendable value type, extracting attendee names + emails,
    /// the organizer, location, and a derived online/onsite signal. Returns nil when the
    /// event lacks usable start/end dates (it can't be scored against the recording span).
    private static func makeCalendarEvent(from ekEvent: EKEvent) -> CalendarEvent? {
        guard let start = ekEvent.startDate, let end = ekEvent.endDate else { return nil }
        let attendees: [CalendarEvent.Person] = (ekEvent.attendees ?? []).compactMap(makePerson)
        let location = ekEvent.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = ekEvent.notes ?? ""

        // EventKit has no explicit online flag; infer from the URL, location, or notes.
        let onlineHint = [ekEvent.url?.absoluteString, ekEvent.location, notes]
            .compactMap { $0 }
            .joined(separator: " ")
        let isOnline = CalendarEvent.looksOnline(onlineHint) ? true : nil

        return CalendarEvent(
            uid: ekEvent.eventIdentifier,
            title: ekEvent.title ?? "",
            attendees: attendees,
            organizer: ekEvent.organizer.flatMap(makePerson),
            body: notes,
            location: (location?.isEmpty == false) ? location : nil,
            isOnline: isOnline,
            isAllDay: ekEvent.isAllDay,
            startDate: start,
            endDate: end
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

/// Resolves a persisted iCal allow-list against calendars that currently exist. `nil` keeps
/// EventKit's all-calendars behavior; an explicit selection can only shrink and never broadens
/// when one or more selected calendars disappear.
enum ICalCalendarFilter {
    static func resolvedIdentifiers(
        available: [String],
        selected: Set<String>?
    ) -> Set<String>? {
        guard let selected else { return nil }
        return selected.intersection(Set(available))
    }
}
