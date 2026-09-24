import Foundation

extension ProcessingPipeline {
    /// One optional, job-owned operation. Terminal records are reused during
    /// recovery; only a durable pending record may issue a connector read.
    func enrichCalendarParticipants(
        prior: CalendarParticipantEnrichmentRecord,
        frozenConfiguration: CalendarParticipantRequestConfiguration?,
        currentConfiguration: CalendarCLIConfig?,
        fetch: @Sendable (CalendarCLIEntry, CalendarCLIConfig) async throws -> CalendarCLIEntry
    ) async throws -> CalendarParticipantEnrichmentRecord {
        try Task.checkCancellation()
        guard prior.state == .pending else { return prior }
        guard let selection = prior.selection else {
            return .init(selection: nil, state: .skipped, completedAt: now())
        }
        guard let frozenConfiguration, let currentConfiguration,
              frozenConfiguration.scope == selection.scope,
              selection.entry.key.mailbox == selection.scope.mailbox,
              selection.entry.key.calendar == selection.scope.calendar,
              let config = frozenConfiguration.restoredConfig(using: currentConfiguration) else {
            return .init(selection: selection, state: .warning, completedAt: now())
        }
        do {
            let resolved = try await fetch(selection.entry, config)
            try Task.checkCancellation()
            guard resolved.key == selection.entry.key else {
                return .init(selection: selection, state: .warning, completedAt: now())
            }
            switch resolved.attendeeState {
            case .loaded, .none, .omittedLargeMeeting:
                let count = resolved.attendeeCount ?? resolved.event.attendees.count
                if count > config.maxAttendees, resolved.attendeeState == .loaded {
                    return .init(selection: selection, state: .warning, completedAt: now())
                }
                return .init(selection: selection, state: .completed,
                             resolvedEntry: resolved, completedAt: now())
            case .notRequested, .unavailable, .stale:
                return .init(selection: selection, state: .warning, completedAt: now())
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .init(selection: selection, state: .warning, completedAt: now())
        }
    }
}
