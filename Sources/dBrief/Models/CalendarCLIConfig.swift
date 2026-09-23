import Foundation

/// Configuration for the Claude CLI calendar source. Fully independent of the
/// AI-analysis CLI configuration (`LocalCLIConfig`) and of the AI-engine
/// selection: calendar fetching must never alter transcription or analysis.
///
/// The mailbox email is required — it makes the query target explicit and is
/// passed to the connector as `calendarOwnerEmail`, so a connector login change
/// cannot silently redirect a request to a different default mailbox.
struct CalendarCLIConfig: Codable, Sendable, Equatable {
    enum AttendeePolicy: String, Codable, Sendable {
        /// Rosters load only through an explicit user action per meeting.
        case onDemand
        /// Never fetch rosters; attendee data stays unloaded for this source.
        case never
    }

    /// Model passed as a single `--model` argv value; `nil` keeps the Claude
    /// default (the `--model` flag is omitted entirely). Never a shell string.
    var modelID: String?

    /// Per CLI invocation, covering connector pagination and structured
    /// generation. Clamped to 30–300 seconds.
    var timeoutSeconds: Int

    /// Mailbox that owns the queried calendar. Normalized to lowercase.
    var mailboxEmail: String

    /// Optional calendar name filter. `nil`/empty means the default calendar.
    var calendarName: String?

    /// How long a day list stays fresh; zero means Manual only.
    var listFreshnessSeconds: Int

    /// How long a fetched attendee roster stays fresh.
    var detailFreshnessSeconds: Int

    var attendeePolicy: AttendeePolicy

    /// Rosters above this size are omitted entirely rather than truncated.
    /// Clamped to 1–100.
    var maxAttendees: Int

    /// Optional advanced command override. `nil` uses the managed Claude
    /// command. The override must not carry conflicting output/tool flags;
    /// `validate()` rejects them.
    var command: String?

    static let defaultTimeoutSeconds = 90
    static let defaultListFreshnessSeconds = 60 * 60
    static let defaultDetailFreshnessSeconds = 60 * 60
    static let defaultMaxAttendees = 20

    static let `default` = CalendarCLIConfig(
        modelID: nil,
        timeoutSeconds: defaultTimeoutSeconds,
        mailboxEmail: "",
        calendarName: nil,
        listFreshnessSeconds: defaultListFreshnessSeconds,
        detailFreshnessSeconds: defaultDetailFreshnessSeconds,
        attendeePolicy: .onDemand,
        maxAttendees: defaultMaxAttendees,
        command: nil
    )

    /// Assigns values verbatim; `init` normalizes before delegating here.
    init(
        raw modelID: String?,
        timeoutSeconds: Int,
        mailboxEmail: String,
        calendarName: String?,
        listFreshnessSeconds: Int,
        detailFreshnessSeconds: Int,
        attendeePolicy: AttendeePolicy,
        maxAttendees: Int,
        command: String?
    ) {
        self.modelID = modelID
        self.timeoutSeconds = timeoutSeconds
        self.mailboxEmail = mailboxEmail
        self.calendarName = calendarName
        self.listFreshnessSeconds = listFreshnessSeconds
        self.detailFreshnessSeconds = detailFreshnessSeconds
        self.attendeePolicy = attendeePolicy
        self.maxAttendees = maxAttendees
        self.command = command
    }

    /// Test-only construction without normalization (fast transport timeouts).
    static func unnormalized(
        modelID: String? = nil,
        timeoutSeconds: Int,
        mailboxEmail: String = "",
        calendarName: String? = nil,
        listFreshnessSeconds: Int = defaultListFreshnessSeconds,
        detailFreshnessSeconds: Int = defaultDetailFreshnessSeconds,
        attendeePolicy: AttendeePolicy = .onDemand,
        maxAttendees: Int = defaultMaxAttendees,
        command: String? = nil
    ) -> CalendarCLIConfig {
        CalendarCLIConfig(
            raw: modelID, timeoutSeconds: timeoutSeconds, mailboxEmail: mailboxEmail,
            calendarName: calendarName, listFreshnessSeconds: listFreshnessSeconds,
            detailFreshnessSeconds: detailFreshnessSeconds, attendeePolicy: attendeePolicy,
            maxAttendees: maxAttendees, command: command
        )
    }

    /// Normalizing init used by UI, persistence and `updating`.
    init(
        modelID: String?,
        timeoutSeconds: Int,
        mailboxEmail: String,
        calendarName: String?,
        listFreshnessSeconds: Int,
        detailFreshnessSeconds: Int,
        attendeePolicy: AttendeePolicy,
        maxAttendees: Int,
        command: String?
    ) {
        self.init(
            raw: Self.sanitizedModelID(modelID),
            timeoutSeconds: Self.normalizedTimeout(timeoutSeconds),
            mailboxEmail: Self.normalizedMailbox(mailboxEmail),
            calendarName: Self.normalizedCalendarName(calendarName),
            listFreshnessSeconds: Self.normalizedListFreshness(listFreshnessSeconds),
            detailFreshnessSeconds: max(60, detailFreshnessSeconds),
            attendeePolicy: attendeePolicy,
            maxAttendees: Self.normalizedMaxAttendees(maxAttendees),
            command: command
        )
    }

    /// Backwards-compatible decoding: unknown/older files fall back to defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            modelID: try container.decodeIfPresent(String.self, forKey: .modelID),
            timeoutSeconds: try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? Self.defaultTimeoutSeconds,
            mailboxEmail: try container.decodeIfPresent(String.self, forKey: .mailboxEmail) ?? "",
            calendarName: try container.decodeIfPresent(String.self, forKey: .calendarName),
            listFreshnessSeconds: try container.decodeIfPresent(Int.self, forKey: .listFreshnessSeconds) ?? Self.defaultListFreshnessSeconds,
            detailFreshnessSeconds: try container.decodeIfPresent(Int.self, forKey: .detailFreshnessSeconds) ?? Self.defaultDetailFreshnessSeconds,
            attendeePolicy: try container.decodeIfPresent(AttendeePolicy.self, forKey: .attendeePolicy) ?? .onDemand,
            maxAttendees: try container.decodeIfPresent(Int.self, forKey: .maxAttendees) ?? Self.defaultMaxAttendees,
            command: try container.decodeIfPresent(String.self, forKey: .command)
        )
    }

    var isConfigured: Bool {
        !mailboxEmail.isEmpty
    }

    /// A model ID is passed as one argv value via an environment variable, so it
    /// must be a plain token (no whitespace, quotes or shell metacharacters).
    static func sanitizedModelID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._/".contains($0)) })
        else { return nil }
        return value
    }

    static func normalizedMailbox(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizedCalendarName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func normalizedTimeout(_ raw: Int) -> Int {
        min(300, max(30, raw))
    }

    static func normalizedListFreshness(_ raw: Int) -> Int {
        raw == 0 ? 0 : min(24 * 60 * 60, max(5 * 60, raw))
    }

    static func normalizedMaxAttendees(_ raw: Int) -> Int {
        min(100, max(1, raw))
    }

    /// Result replacement for an edited configuration.
    func updating(
        modelID: String?? = nil,
        timeoutSeconds: Int? = nil,
        mailboxEmail: String? = nil,
        calendarName: String?? = nil,
        listFreshnessSeconds: Int? = nil,
        detailFreshnessSeconds: Int? = nil,
        attendeePolicy: AttendeePolicy? = nil,
        maxAttendees: Int? = nil,
        command: String?? = nil
    ) -> CalendarCLIConfig {
        CalendarCLIConfig(
            modelID: modelID ?? self.modelID,
            timeoutSeconds: timeoutSeconds ?? self.timeoutSeconds,
            mailboxEmail: mailboxEmail ?? self.mailboxEmail,
            calendarName: calendarName ?? self.calendarName,
            listFreshnessSeconds: listFreshnessSeconds ?? self.listFreshnessSeconds,
            detailFreshnessSeconds: detailFreshnessSeconds ?? self.detailFreshnessSeconds,
            attendeePolicy: attendeePolicy ?? self.attendeePolicy,
            maxAttendees: maxAttendees ?? self.maxAttendees,
            command: command ?? self.command
        )
    }

    /// The managed command never embeds user data; dynamic values (schema,
    /// model) flow through quoted environment variables, prompt data on stdin.
    static let managedCommandPrefix = #"claude -p --no-session-persistence --output-format json --json-schema "$DBRIEF_CALENDAR_SCHEMA""#

    /// Managed headless invocation: one allowlisted read-only connector tool,
    /// every other tool denied without prompting (`--permission-prompts none`).
    /// This is the read-only tool boundary; the prompt alone is not.
    static func managedCommand(allowedTool: String, modelID: String?) -> String {
        var command = managedCommandPrefix
        if sanitizedModelID(modelID) != nil {
            command += #" --model "$DBRIEF_CALENDAR_MODEL""#
        }
        command += " --allowedTools \(allowedTool) --permission-prompts none"
        return command
    }

    /// An advanced command must not re-declare flags the runner appends, and
    /// must not carry environment expansion of unknown variables.
    func validateCommand() -> Bool {
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let forbidden = [
            "--model", "--output-format", "--json-schema",
            "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools",
            "--permission-prompts", "--permission-mode",
        ]
        return !forbidden.contains { command.contains($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case modelID, timeoutSeconds, mailboxEmail, calendarName
        case listFreshnessSeconds, detailFreshnessSeconds, attendeePolicy, maxAttendees, command
    }
}
