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

    private func fetchCandidates(
        recordingStart: Date,
        recordingEnd: Date,
        token: String
    ) async throws -> [CalendarEvent] {
        var components = URLComponents(string: Self.calendarViewURL)!
        components.queryItems = [
            URLQueryItem(name: "startDateTime", value: graphDateString(recordingStart.addingTimeInterval(-searchWindow))),
            URLQueryItem(name: "endDateTime",   value: graphDateString(recordingEnd.addingTimeInterval(searchWindow))),
            URLQueryItem(name: "$select",       value: "subject,bodyPreview,attendees,start,end,isAllDay"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let result = try JSONDecoder().decode(CalendarViewResponse.self, from: data)
        let candidates = result.value.map { Self.makeCalendarEvent(from: $0) }
        return CalendarMatcher.rankedMatches(
            from: candidates, recordingStart: recordingStart, recordingEnd: recordingEnd
        )
    }

    // MARK: - JSON types

    private struct CalendarViewResponse: Decodable {
        let value: [GraphEvent]
    }

    private struct GraphEvent: Decodable {
        let subject: String?
        let bodyPreview: String?
        let attendees: [GraphAttendee]?
        let start: GraphDateTimeZone?
        let end: GraphDateTimeZone?
        let isAllDay: Bool?
    }

    private struct GraphAttendee: Decodable {
        let emailAddress: GraphEmailAddress?
    }

    private struct GraphEmailAddress: Decodable {
        let name: String?
    }

    private struct GraphDateTimeZone: Decodable {
        let dateTime: String?
    }

    // MARK: - Mapping

    private static func makeCalendarEvent(from event: GraphEvent) -> CalendarEvent {
        let names: [String] = (event.attendees ?? []).compactMap { attendee in
            let name = attendee.emailAddress?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }
        return CalendarEvent(
            title: event.subject ?? "",
            attendees: names,
            body: event.bodyPreview ?? "",
            startDate: parseGraphDate(event.start?.dateTime),
            endDate: parseGraphDate(event.end?.dateTime),
            isAllDay: event.isAllDay ?? false
        )
    }

    /// Graph calendarView returns UTC dates without 'Z': "2026-06-04T10:00:00.0000000"
    private static func parseGraphDate(_ string: String?) -> Date {
        guard let string else { return Date() }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS"
        if let d = f.date(from: string) { return d }
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: string) ?? Date()
    }

    /// ISO 8601 format expected by Graph query parameters.
    private func graphDateString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
