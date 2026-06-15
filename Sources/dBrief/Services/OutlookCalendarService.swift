import Foundation
import OSLog

actor OutlookCalendarService {
    private let authService: MicrosoftAuthService
    private let searchWindow: TimeInterval = 2 * 60 * 60  // ±2 hours
    private static let calendarViewURL = "https://graph.microsoft.com/v1.0/me/calendarView"

    init(authService: MicrosoftAuthService) {
        self.authService = authService
    }

    /// Ranked calendar events plausibly matching the recording span, best-first. Empty on failure.
    func findCandidates(recordingStart: Date, recordingEnd: Date) async -> [CalendarEvent] {
        do {
            let token = try await authService.getValidAccessToken()
            return try await fetchCandidates(
                recordingStart: recordingStart, recordingEnd: recordingEnd, token: token
            )
        } catch {
            Logger.calendar.error("Outlook calendar fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Private

    private func fetchCandidates(
        recordingStart: Date,
        recordingEnd: Date,
        token: String
    ) async throws -> [CalendarEvent] {
        var components = URLComponents(string: Self.calendarViewURL)!
        components.queryItems = [
            URLQueryItem(name: "startDateTime", value: graphDateString(recordingStart.addingTimeInterval(-searchWindow))),
            URLQueryItem(name: "endDateTime",   value: graphDateString(recordingEnd.addingTimeInterval(searchWindow))),
            URLQueryItem(name: "$select",       value: "id,subject,bodyPreview,body,attendees,organizer,location,isOnlineMeeting,isAllDay,start,end"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let result = try JSONDecoder().decode(CalendarViewResponse.self, from: data)
        let candidates = result.value.compactMap { Self.makeCalendarEvent(from: $0) }
        return CalendarMatcher.rankedMatches(
            from: candidates, recordingStart: recordingStart, recordingEnd: recordingEnd
        )
    }

    // MARK: - JSON types

    private struct CalendarViewResponse: Decodable {
        let value: [GraphEvent]
    }

    private struct GraphEvent: Decodable {
        let id: String?
        let subject: String?
        let bodyPreview: String?
        let body: GraphItemBody?
        let attendees: [GraphAttendee]?
        let organizer: GraphAttendee?
        let location: GraphLocation?
        let isOnlineMeeting: Bool?
        let isAllDay: Bool?
        let start: GraphDateTimeZone?
        let end: GraphDateTimeZone?
    }

    private struct GraphAttendee: Decodable {
        let emailAddress: GraphEmailAddress?
    }

    private struct GraphEmailAddress: Decodable {
        let name: String?
        let address: String?
    }

    private struct GraphItemBody: Decodable {
        let contentType: String?
        let content: String?
    }

    private struct GraphLocation: Decodable {
        let displayName: String?
    }

    private struct GraphDateTimeZone: Decodable {
        let dateTime: String?
    }

    // MARK: - Mapping

    /// Returns nil when the event lacks parseable start/end dates (it can't be scored against
    /// the recording span) — never silently defaulting to "now", which would corrupt matching.
    private static func makeCalendarEvent(from event: GraphEvent) -> CalendarEvent? {
        guard let start = parseGraphDate(event.start?.dateTime),
              let end = parseGraphDate(event.end?.dateTime) else { return nil }
        let attendees = (event.attendees ?? []).compactMap { makePerson(from: $0.emailAddress) }
        let location = event.location?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefer the full body (verbatim agenda), stripping HTML; fall back to bodyPreview.
        let agenda: String
        if let body = event.body?.content, !body.isEmpty {
            agenda = (event.body?.contentType?.lowercased() == "html") ? stripHTML(body) : body
        } else {
            agenda = event.bodyPreview ?? ""
        }

        return CalendarEvent(
            uid: event.id,
            title: event.subject ?? "",
            attendees: attendees,
            organizer: makePerson(from: event.organizer?.emailAddress),
            body: agenda,
            location: (location?.isEmpty == false) ? location : nil,
            isOnline: event.isOnlineMeeting,
            isAllDay: event.isAllDay ?? false,
            startDate: start,
            endDate: end
        )
    }

    private static func makePerson(from email: GraphEmailAddress?) -> CalendarEvent.Person? {
        guard let email else { return nil }
        let name = email.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = email.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEmail = (address?.isEmpty == false) ? address : nil
        if name.isEmpty, cleanEmail == nil { return nil }
        return CalendarEvent.Person(name: name.isEmpty ? (cleanEmail ?? "") : name, email: cleanEmail)
    }

    /// Minimal HTML→text: drops tags, decodes a few common entities, collapses blank lines.
    private static func stripHTML(_ html: String) -> String {
        let withBreaks = html
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</p>", with: "\n", options: .regularExpression)
        let noTags = withBreaks.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = noTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        return decoded
            .replacingOccurrences(of: "\n[ \\t]*\n[ \\t]*(\n[ \\t]*)+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Graph calendarView returns UTC dates without 'Z', with up to 7 fractional digits:
    /// "2026-06-04T10:00:00.0000000". `DateFormatter`'s fractional-second support is only
    /// reliable to milliseconds, so normalize by dropping any fractional part (sub-second
    /// precision is irrelevant for minute-granularity calendar matching) and parse the
    /// integer-seconds form. Returns nil on failure rather than defaulting to the current
    /// date, which would silently corrupt span matching.
    private static func parseGraphDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let normalized = string.replacingOccurrences(
            of: "(\\.\\d+)?Z?$", with: "", options: .regularExpression
        )
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: normalized)
    }

    /// ISO 8601 format expected by Graph query parameters.
    private func graphDateString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
