import Foundation

enum CalendarLinkSelectionID: Hashable {
    case cli(CalendarCLIOccurrenceKey)
    case event(String)
}

/// Calendar days and their read outcomes travel with the events so an empty
/// list can be distinguished from an unavailable list in the link sheet.
struct CalendarLinkMeetingList: Sendable {
    let recordingStart: Date
    let recordingEnd: Date
    let events: [CalendarEvent]
    let cliDays: [CalendarCLIListRead]

    func selectionID(for event: CalendarEvent) -> CalendarLinkSelectionID {
        for day in cliDays {
            if let entry = day.entries.first(where: { $0.event.id == event.id }) {
                return .cli(entry.key)
            }
        }
        return .event(event.id)
    }

    var emptyMessage: String? {
        guard events.isEmpty else { return nil }
        if cliDays.isEmpty { return "No meetings were found for this date." }
        if cliDays.allSatisfy(\.hasCompleteSnapshot) { return "No meetings found for this date." }
        return nil
    }

    var statusMessage: String? {
        guard !cliDays.isEmpty else { return nil }
        if cliDays.contains(where: { $0.persistence == .failed }) {
            return "Loaded, but could not save the cache."
        }
        if cliDays.contains(where: { $0.outcome == .blocked }) {
            return "Calendar access is blocked. Check connector approval, then refresh this date."
        }
        if cliDays.contains(where: { $0.outcome == .failed }) {
            return "Calendar refresh failed. Saved meetings remain available."
        }
        if cliDays.contains(where: { $0.outcome == .partial }) {
            return "Calendar refresh was incomplete. Saved meetings remain available."
        }
        if cliDays.contains(where: { $0.outcome == .manualOnly }) {
            return "Automatic loading is off. Press Refresh this date."
        }
        if let last = cliDays.compactMap(\.lastSuccessfulRefresh).max() {
            return "Cached · refreshed \(last.formatted(date: .abbreviated, time: .shortened))"
        }
        return nil
    }
}
