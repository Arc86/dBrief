import Foundation

/// A calendar event matched to a recording, carrying only the fields dBrief needs.
/// EventKit / Microsoft Graph types are never exposed outside their services.
struct CalendarEvent: Sendable, Equatable, Codable {
    /// A meeting participant: a display name and (when the calendar provides it) an email,
    /// which is the stable key for matching people downstream.
    struct Person: Sendable, Equatable, Codable {
        let name: String
        let email: String?

        /// The domain portion of `email`, lowercased (e.g. "acme.com"), or nil.
        var emailDomain: String? {
            guard let email, let at = email.lastIndex(of: "@") else { return nil }
            let domain = email[email.index(after: at)...].lowercased()
            return domain.isEmpty ? nil : domain
        }
    }

    let title: String
    let attendees: [Person]
    let organizer: Person?
    let body: String          // notes / description / agenda
    let location: String?
    /// Whether the event is an online meeting (Zoom/Teams/Meet/etc.). nil when unknown.
    let isOnline: Bool?
    let startDate: Date
    let endDate: Date

    init(
        title: String,
        attendees: [Person],
        organizer: Person? = nil,
        body: String,
        location: String? = nil,
        isOnline: Bool? = nil,
        startDate: Date,
        endDate: Date
    ) {
        self.title = title
        self.attendees = attendees
        self.organizer = organizer
        self.body = body
        self.location = location
        self.isOnline = isOnline
        self.startDate = startDate
        self.endDate = endDate
    }

    /// Comma-separated attendee names, for pre-filling the participants field and mapping
    /// diarization speakers in order of first appearance.
    var participantsText: String {
        attendees.map(\.name).joined(separator: ", ")
    }

    /// Derived meeting modality: "online" when flagged online, "onsite" when a physical
    /// location is present, otherwise "unknown". Downstream AI/agents make finer calls
    /// (e.g. "onsite customer") from this plus the participant signals below.
    var modality: String {
        if isOnline == true { return "online" }
        if let location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "onsite"
        }
        return "unknown"
    }

    /// Attendee email domains that differ from the organizer's domain — a signal that
    /// external parties (e.g. a customer) are present. Empty when the organizer's domain
    /// is unknown or all attendees share it.
    var externalDomains: [String] {
        guard let host = organizer?.emailDomain else { return [] }
        let domains = attendees.compactMap(\.emailDomain).filter { $0 != host }
        return Array(Set(domains)).sorted()
    }

    var hasExternalParticipants: Bool {
        !externalDomains.isEmpty
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

    /// Known online-meeting host fragments used to derive `isOnline` from a URL/location/notes
    /// blob when the calendar source doesn't expose an explicit flag.
    static let onlineMeetingHints = [
        "zoom.us", "teams.microsoft", "teams.live", "meet.google", "webex.com",
        "whereby.com", "gotomeeting.com", "bluejeans.com", "chime.aws",
    ]

    /// Returns true when `text` contains a known online-meeting host fragment.
    static func looksOnline(_ text: String?) -> Bool {
        guard let text = text?.lowercased(), !text.isEmpty else { return false }
        return onlineMeetingHints.contains { text.contains($0) }
    }
}
