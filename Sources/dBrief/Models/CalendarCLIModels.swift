import Foundation
import CryptoKit

/// The local day window a cached snapshot covers. Boundaries are absolute
/// instants computed with `Calendar` in the user's local time zone (never
/// +86400 arithmetic); `timeZoneID` is part of the identity so a travel change
/// cannot silently reuse a window computed for a different zone.
struct CalendarCLIWindow: Codable, Hashable, Sendable {
    let start: Date
    let end: Date
    let timeZoneID: String
}

/// Persistent identity of one calendar occurrence. Deliberately independent of
/// `CalendarEvent.id`, which folds in attendee names and therefore changes when
/// rosters load.
struct CalendarCLIOccurrenceKey: Codable, Hashable, Sendable {
    let mailbox: String
    let calendar: String
    let resourceURI: String
    let occurrenceStart: Date
}

/// Roster state of one occurrence.
enum CalendarCLIAttendeeState: String, Codable, Sendable {
    case notRequested
    case loaded
    /// The source verified zero attendees.
    case none
    /// A verified count exceeded the configured cap; the whole roster is
    /// omitted rather than exporting the first N invitees.
    case omittedLargeMeeting
    /// Completeness or count could not be established.
    case unavailable
    /// Derived (not persisted by fetches): a previously loaded roster whose
    /// source revision or freshness no longer holds.
    case stale
}

enum CalendarCLICompleteness: String, Codable, Sendable {
    case complete, partial, blocked
}

/// One cached calendar occurrence. `event` always carries an empty body for
/// this source: invite bodies are never output, persisted, or analyzed.
/// List-stage entries carry an empty attendee array; rosters only ever load
/// through an explicit user request recorded in `attendeeState`.
struct CalendarCLIEntry: Codable, Sendable, Equatable {
    let key: CalendarCLIOccurrenceKey
    let event: CalendarEvent
    /// Source-provided modification marker (e.g. the connector's
    /// `lastModifiedDateTime`), verbatim. `nil` when the list stage has not
    /// supplied one; absence never implies unchanged content.
    let sourceRevision: String?
    /// When the roster was explicitly fetched. Never set by list refreshes.
    let detailsFetchedAt: Date?
    let attendeeState: CalendarCLIAttendeeState
    /// Source-supported attendee count from the fixed tool response. Never a
    /// model estimate of unseen data.
    let attendeeCount: Int?
    /// Cancellation state from the source. Kept outside `CalendarEvent`, which
    /// has no cancellation field; presentation decides whether to surface it.
    let isCancelled: Bool

    init(
        key: CalendarCLIOccurrenceKey,
        event: CalendarEvent,
        sourceRevision: String?,
        detailsFetchedAt: Date?,
        attendeeState: CalendarCLIAttendeeState,
        attendeeCount: Int?,
        isCancelled: Bool = false
    ) {
        self.key = key
        self.event = event
        self.sourceRevision = sourceRevision
        self.detailsFetchedAt = detailsFetchedAt
        self.attendeeState = attendeeState
        self.attendeeCount = attendeeCount
        self.isCancelled = isCancelled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(CalendarCLIOccurrenceKey.self, forKey: .key),
            event: try container.decode(CalendarEvent.self, forKey: .event),
            sourceRevision: try container.decodeIfPresent(String.self, forKey: .sourceRevision),
            detailsFetchedAt: try container.decodeIfPresent(Date.self, forKey: .detailsFetchedAt),
            attendeeState: try container.decodeIfPresent(CalendarCLIAttendeeState.self, forKey: .attendeeState) ?? .notRequested,
            attendeeCount: try container.decodeIfPresent(Int.self, forKey: .attendeeCount),
            isCancelled: try container.decodeIfPresent(Bool.self, forKey: .isCancelled) ?? false
        )
    }

    func replacing(event: CalendarEvent) -> CalendarCLIEntry {
        CalendarCLIEntry(
            key: key, event: event, sourceRevision: sourceRevision,
            detailsFetchedAt: detailsFetchedAt, attendeeState: attendeeState,
            attendeeCount: attendeeCount, isCancelled: isCancelled
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key, event, sourceRevision, detailsFetchedAt, attendeeState, attendeeCount, isCancelled
    }
}

struct CalendarCLIListResult: Sendable {
    let entries: [CalendarCLIEntry]
    let completeness: CalendarCLICompleteness
    let message: String?
}

/// Identity of a cache scope: provider plus the explicitly configured mailbox,
/// calendar name and time zone. Storage filenames are hashes of the encoded
/// scope — the CLI command itself is never part of a filesystem path.
struct CalendarCLIScope: Codable, Hashable, Sendable {
    static let provider = "claudeCLI"

    let mailbox: String
    let calendar: String
    let timeZoneID: String

    init(config: CalendarCLIConfig, timeZoneID: String = TimeZone.current.identifier) {
        self.mailbox = CalendarCLIConfig.normalizedMailbox(config.mailboxEmail)
        self.calendar = CalendarCLIConfig.normalizedCalendarName(config.calendarName) ?? ""
        self.timeZoneID = timeZoneID
    }

    init(mailbox: String, calendar: String, timeZoneID: String) {
        self.mailbox = mailbox
        self.calendar = calendar
        self.timeZoneID = timeZoneID
    }

    /// Stable digest for storage filenames (never the raw command).
    var digest: String {
        let identity = [Self.provider, mailbox, calendar, timeZoneID].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }
}

// MARK: - CLI result envelope

/// The `claude --output-format json` envelope. `structuredOutput` carries the
/// schema-constrained payload; a successful subtype with a missing payload is
/// an incomplete structured generation and is rejected.
struct CalendarCLIResultEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    struct Usage: Decodable, Sendable {
        let input_tokens: Int?
        let output_tokens: Int?
    }

    let subtype: String?
    let is_error: Bool?
    let structuredOutput: Payload?
    let usage: Usage?
    let num_turns: Int?
    let duration_api_ms: Int?

    enum CodingKeys: String, CodingKey {
        case subtype, usage, num_turns, duration_api_ms
        case is_error = "is_error"
        case structuredOutput = "structured_output"
    }
}

/// Usage-only envelope: decoding ignores `structured_output` entirely, so the
/// same type extracts usage metadata from any response.
struct CalendarCLIUsageEnvelope: Decodable, Sendable {
    struct Usage: Decodable, Sendable {
        let input_tokens: Int?
        let output_tokens: Int?
    }

    let is_error: Bool?
    let usage: Usage?
}

// MARK: - Structured payloads

/// Versioned payload the model must return for a day-list fetch. All dynamic
/// values (request ID, mailbox, window) are echoed so responses cannot be
/// replayed across requests, mailboxes or windows.
struct CalendarCLIResponseEnvelope: Decodable, Sendable {
    struct Event: Decodable, Sendable {
        let uri: String
        let id: String
        let title: String
        let organizerEmail: String?
        let attendeeCount: Int?
        /// Connector `start.dateTime`, echoed verbatim (UTC naive ISO-8601).
        let startUTC: String
        let endUTC: String
        let isCancelled: Bool
        let isAllDay: Bool
        let location: String?
    }

    let v: Int
    let requestID: String
    /// complete | partial | blocked
    let status: String
    let mailbox: String
    /// Echoed window bounds as ISO strings (copied from the request).
    let windowStart: String
    let windowEnd: String
    let events: [Event]
    let paginationComplete: Bool
    let totalResultCount: Int?
    let error: String?
}

/// Versioned payload for an explicit roster fetch of exactly one occurrence.
struct CalendarCLIDetailEnvelope: Decodable, Sendable {
    struct Person: Decodable, Sendable {
        let name: String
        let email: String
    }

    let v: Int
    let requestID: String
    let status: String
    let uri: String
    let startUTC: String
    let endUTC: String
    /// loaded | none | omittedLargeMeeting | unavailable
    let attendeeState: String
    let attendeeCount: Int?
    let revision: String?
    let people: [Person]
    let error: String?
}

// MARK: - Connector time parsing

enum CalendarCLITimeParsing {
    /// Parses the connector's UTC naive ISO-8601 form
    /// (`2026-09-22T07:15:00.0000000`, up to 7 fractional digits) as well as
    /// the `Z`-suffixed variant. Returns nil for anything else — malformed
    /// dates are a validation failure, never silently coerced.
    static func connectorUTCDate(_ raw: String) -> Date? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasSuffix("Z") || value.hasSuffix("z") { value.removeLast() }
        guard value.count >= 19 else { return nil } // YYYY-MM-DDTHH:MM:SS
        if let dot = value.firstIndex(of: ".") {
            let digits = value[value.index(after: dot)...]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            let millis = digits.prefix(3)
            value = String(value[..<dot]) + "." + millis + String(repeating: "0", count: 3 - millis.count)
        }
        // The connector's naive times are UTC (its timeZone field says so).
        value += "Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
