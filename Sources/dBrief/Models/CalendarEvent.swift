import Foundation

/// A calendar event matched to a recording, carrying only the fields dBrief needs.
/// EventKit types are never exposed outside `CalendarService`.
struct CalendarEvent: Sendable, Equatable, Identifiable {
    let title: String
    let attendees: [String]   // display names only
    let body: String          // notes / description / agenda
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool

    /// Stable identity for SwiftUI selection. Calendar sources don't expose a uid here,
    /// so derive it from the fields that distinguish overlapping events.
    var id: String {
        "\(title)|\(startDate.timeIntervalSince1970)|\(endDate.timeIntervalSince1970)|\(attendees.joined(separator: ","))"
    }

    /// Comma-separated attendee names, for pre-filling the participants field.
    var participantsText: String {
        attendees.joined(separator: ", ")
    }

    /// Prepends this event's agenda to a base AI system prompt. Returns the base prompt
    /// unchanged when `event` is nil or its body is blank.
    static func augment(prompt basePrompt: String, with event: CalendarEvent?) -> String {
        guard let body = event?.body,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return basePrompt
        }
        return "Meeting context from calendar:\n\(body)\n\n\(basePrompt)"
    }
}
