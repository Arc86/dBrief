import Foundation
import CryptoKit

/// The selected occurrence is frozen before a queued or live job begins.
/// CalendarEvent.id is unsuitable because loading attendees changes that ID.
struct CalendarParticipantSelection: Codable, Equatable, Sendable {
    let scope: CalendarCLIScope
    let entry: CalendarCLIEntry
}

struct CalendarParticipantAdmission: Sendable {
    let selection: CalendarParticipantSelection?
    let configuration: CalendarParticipantRequestConfiguration?
    let isNative: Bool

    init(selection: CalendarParticipantSelection?,
         configuration: CalendarParticipantRequestConfiguration?, isNative: Bool = false) {
        self.selection = selection
        self.configuration = configuration
        self.isNative = isNative
    }

    static let none = Self(selection: nil, configuration: nil)
}

enum CalendarParticipantEnrichmentState: String, Codable, Sendable {
    case pending, completed, skipped, warning
}

struct CalendarParticipantEnrichmentRecord: Codable, Equatable, Sendable {
    let selection: CalendarParticipantSelection?
    var state: CalendarParticipantEnrichmentState
    var resolvedEntry: CalendarCLIEntry?
    var completedAt: Date?

    init(selection: CalendarParticipantSelection?, state: CalendarParticipantEnrichmentState = .pending,
         resolvedEntry: CalendarCLIEntry? = nil, completedAt: Date? = nil) {
        self.selection = selection
        self.state = state
        self.resolvedEntry = resolvedEntry
        self.completedAt = completedAt
    }
}

/// Recovery may reuse current CLI settings only when they still match this
/// accepted request. The raw command and credentials never enter the journal.
struct CalendarParticipantRequestConfiguration: Codable, Equatable, Sendable {
    let modelID: String?
    let effort: CLIReasoningEffort
    let timeoutSeconds: Int
    let maxAttendees: Int
    let scope: CalendarCLIScope
    let commandDigest: String

    init(config: CalendarCLIConfig, scope: CalendarCLIScope) {
        modelID = config.modelID
        effort = config.effort
        timeoutSeconds = config.timeoutSeconds
        maxAttendees = config.maxAttendees
        self.scope = scope
        commandDigest = Self.digest(config.command)
    }

    func matches(config: CalendarCLIConfig, scope: CalendarCLIScope) -> Bool {
        self == Self(config: config, scope: scope)
    }

    /// Uses only the current command when its digest and target still match;
    /// model, effort and timeout remain frozen from job admission. A lowered
    /// current cap and Never policy still take effect before any read.
    func restoredConfig(using current: CalendarCLIConfig) -> CalendarCLIConfig? {
        guard current.attendeePolicy == .onDemand,
              CalendarCLIScope(config: current) == scope,
              Self.digest(current.command) == commandDigest else { return nil }
        return current.updating(modelID: .some(modelID), effort: effort,
            timeoutSeconds: timeoutSeconds, maxAttendees: min(maxAttendees, current.maxAttendees))
    }

    private static func digest(_ command: String?) -> String {
        let source = command ?? "managed-claude-calendar-command-v1"
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
