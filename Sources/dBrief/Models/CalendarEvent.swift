import Foundation

/// A calendar event matched to a recording, carrying only the fields dBrief needs.
/// EventKit types are never exposed outside `CalendarService`.
struct CalendarEvent: Sendable, Equatable {
    let title: String
    let attendees: [String]   // display names only
    let body: String          // notes / description / agenda
    let startDate: Date
    let endDate: Date

    /// Comma-separated attendee names, for pre-filling the participants field.
    var participantsText: String {
        attendees.joined(separator: ", ")
    }
}
