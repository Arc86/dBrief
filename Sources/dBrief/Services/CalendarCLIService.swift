import Foundation
import os

/// Cache-first orchestration for the Claude CLI calendar source. One actor
/// owns freshness, single-flight coalescing and generation-based
/// cancellation; all disk persistence goes through `CalendarCLICacheStore`.
///
/// Guarantees:
/// - Concurrent refresh callers join one in-flight task per scope/window.
/// - Cancelling one waiter never cancels the shared work of another caller;
///   only `invalidate()`/`configurationChanged(_:)` cancel owned tasks.
/// - Partial, blocked and failed results never replace the last complete
///   snapshot and never advance its success timestamp.
/// - A list refresh never fetches rosters; rosters load only through
///   explicit `detail(entry:config:force:)` calls.
actor CalendarCLIService {
    enum ListAttemptOutcome: Sendable, Equatable {
        case complete, partial, blocked, failed
    }
    private let transport: any CalendarCLITransporting
    private let store: CalendarCLICacheStore
    private let now: @Sendable () -> Date

    /// Advanced on configuration/invalidate so old in-flight results cannot
    /// update the new scope.
    private var generation = 0

    private struct ListFlight {
        let id: UUID
        let task: Task<CalendarCLIListRead, Error>
    }
    private var listTasks: [String: ListFlight] = [:]
    private struct DetailFlight {
        let id: UUID
        let task: Task<CalendarCLIEntry, Error>
    }
    private var detailTasks: [String: DetailFlight] = [:]

    /// Automatic (non-forced) refreshes back off for this long after a failure.
    static let retryCooldown: TimeInterval = 5 * 60
    private var listCooldowns: [String: Date] = [:]
    private var listAttemptOutcomes: [String: ListAttemptOutcome] = [:]
    private var memorySnapshots: [String: CalendarCLIStoredListSnapshot] = [:]
    private var persistenceOutcomes: [String: CalendarCLIPersistenceOutcome] = [:]

    /// Roster scope generation: cap/policy identity. Lowering the cap or
    /// selecting Never invalidates in-flight roster work and purges
    /// incompatible cached rosters.
    private var rosterGeneration: Int = 0

    private var activeRosterScope: (policy: CalendarCLIConfig.AttendeePolicy, cap: Int) = (.onDemand, CalendarCLIConfig.defaultMaxAttendees)

    init(
        transport: any CalendarCLITransporting,
        store: CalendarCLICacheStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.store = store
        self.now = now
    }

    // MARK: - Reads

    /// The unexpired cached snapshot for the window. Staleness of loaded
    /// rosters is derived here (never persisted) from the TTL because list
    /// responses carry no revision data, and the cap is re-applied on every
    /// read so a lowered cap is respected even before a purge runs.
    func cached(window: CalendarCLIWindow, config: CalendarCLIConfig) async -> [CalendarCLIEntry] {
        cachedSnapshot(window: window, config: config).entries
    }

    func cachedSnapshot(window: CalendarCLIWindow, config: CalendarCLIConfig) -> CalendarCLIListRead {
        let scope = CalendarCLIScope(config: config)
        let snapshot = cachedSnapshot(scope: scope, window: window)
        return makeRead(window: window, snapshot: snapshot, config: config,
                        outcome: .cached,
                        persistence: persistenceOutcomes[Self.taskKey(scope: scope, window: window)])
    }

    private func makeRead(window: CalendarCLIWindow, snapshot: CalendarCLIStoredListSnapshot?,
                          config: CalendarCLIConfig, outcome: CalendarCLIListOutcome,
                          persistence: CalendarCLIPersistenceOutcome?) -> CalendarCLIListRead {
        CalendarCLIListRead(window: window,
                            entries: snapshot?.entries.map { adjusted($0, config: config) } ?? [],
                            hasCompleteSnapshot: snapshot != nil,
                            lastSuccessfulRefresh: snapshot?.lastSuccessfulRefresh,
                            lastAttempt: snapshot?.lastAttempt,
                            outcome: outcome, persistence: persistence)
    }

    private func cachedSnapshot(scope: CalendarCLIScope, window: CalendarCLIWindow) -> CalendarCLIStoredListSnapshot? {
        let key = Self.taskKey(scope: scope, window: window)
        if let snapshot = memorySnapshots[key], let success = snapshot.lastSuccessfulRefresh {
            let age = now().timeIntervalSince(success)
            if age >= -300, age < CalendarCLICacheStore.listRetentionInterval { return snapshot }
            memorySnapshots[key] = nil
            persistenceOutcomes[key] = nil
        }
        return store.loadList(scope: scope, window: window)
    }

    /// Read-time adjustments: TTL staleness and cap enforcement. Neither fetches.
    private func adjusted(_ entry: CalendarCLIEntry, config: CalendarCLIConfig) -> CalendarCLIEntry {
        var entry = entry
        if entry.attendeeState == .loaded {
            let people = entry.event.attendees
            if people.count > config.maxAttendees {
                // Present the whole-roster omission rather than a truncated roster.
                entry = CalendarCLIEntry(
                    key: entry.key,
                    event: entry.event.replacing(attendees: []),
                    sourceRevision: entry.sourceRevision,
                    detailsFetchedAt: entry.detailsFetchedAt,
                    attendeeState: .omittedLargeMeeting,
                    attendeeCount: entry.attendeeCount ?? people.count,
                    isCancelled: entry.isCancelled
                )
            } else if !isFresh(entry, config: config, at: now()) {
                entry = markedStale(entry)
            }
        }
        return entry
    }

    func refresh(window: CalendarCLIWindow, config: CalendarCLIConfig, force: Bool) async throws -> [CalendarCLIEntry] {
        let read = try await refreshSnapshot(window: window, config: config, force: force)
        if read.outcome == .failed { throw CalendarCLIServiceError.refreshFailed }
        return read.entries
    }

    func refreshSnapshot(window: CalendarCLIWindow, config: CalendarCLIConfig,
                         force: Bool) async throws -> CalendarCLIListRead {
        try Task.checkCancellation()
        let scope = CalendarCLIScope(config: config)
        let key = Self.taskKey(scope: scope, window: window)
        let currentTime = now()
        let previous = cachedSnapshot(scope: scope, window: window)

        if let existing = listTasks[key] {
            let read = try await existing.task.value
            try Task.checkCancellation()
            return read
        }

        if !force, config.listFreshnessSeconds == 0 {
            return makeRead(window: window, snapshot: previous, config: config,
                            outcome: .manualOnly, persistence: persistenceOutcomes[key])
        }

        if !force, let cooldownUntil = listCooldowns[key], currentTime < cooldownUntil {
            return makeRead(window: window, snapshot: previous, config: config,
                            outcome: listAttemptOutcomes[key] == .partial ? .partial : .blocked,
                            persistence: persistenceOutcomes[key])
        }

        if !CalendarCLIRefreshPolicy.shouldRefresh(window: window,
            lastSuccessfulRefresh: previous?.lastSuccessfulRefresh, now: currentTime,
            freshnessSeconds: config.listFreshnessSeconds, force: force) {
            return makeRead(window: window, snapshot: previous, config: config,
                            outcome: .cached, persistence: persistenceOutcomes[key])
        }

        let id = UUID()
        let startGeneration = generation
        let task = Task<CalendarCLIListRead, Error> {
            try await self.performRefresh(window: window, config: config, scope: scope,
                key: key, previous: previous, generation: startGeneration, id: id)
        }
        listTasks[key] = ListFlight(id: id, task: task)
        let read = try await task.value
        try Task.checkCancellation()
        return read
    }

    private func performRefresh(window: CalendarCLIWindow, config: CalendarCLIConfig,
                                scope: CalendarCLIScope, key: String,
                                previous: CalendarCLIStoredListSnapshot?, generation startGeneration: Int,
                                id: UUID) async throws -> CalendarCLIListRead {
        defer {
            if listTasks[key]?.id == id { listTasks[key] = nil }
        }
        do {
            let result = try await transport.list(window: window, config: config)
            guard generation == startGeneration, !Task.isCancelled else { throw CancellationError() }
            let attempt = now()
            if result.completeness == .complete {
                listAttemptOutcomes[key] = .complete
                listCooldowns[key] = nil
                let snapshot = CalendarCLIStoredListSnapshot(
                    scope: scope, window: window,
                    entries: result.entries,
                    lastSuccessfulRefresh: attempt,
                    lastAttempt: attempt
                )
                memorySnapshots[key] = snapshot
                let persistence = store.storeList(snapshot)
                persistenceOutcomes[key] = persistence
                return makeRead(window: window, snapshot: snapshot, config: config,
                                outcome: .refreshed, persistence: persistence)
            } else {
                let isPartial = result.completeness == .partial
                listAttemptOutcomes[key] = isPartial ? .partial : .blocked
                listCooldowns[key] = attempt.addingTimeInterval(Self.retryCooldown)
                store.updateListAttempt(scope: scope, window: window, date: attempt)
                var retained = previous
                retained?.lastAttempt = attempt
                if let retained { memorySnapshots[key] = retained }
                return makeRead(window: window, snapshot: retained, config: config,
                                outcome: isPartial ? .partial : .blocked,
                                persistence: persistenceOutcomes[key])
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard generation == startGeneration, !Task.isCancelled else { throw CancellationError() }
            let attempt = now()
            listAttemptOutcomes[key] = .failed
            listCooldowns[key] = attempt.addingTimeInterval(Self.retryCooldown)
            store.updateListAttempt(scope: scope, window: window, date: attempt)
            var retained = previous
            retained?.lastAttempt = attempt
            if let retained { memorySnapshots[key] = retained }
            return makeRead(window: window, snapshot: retained, config: config,
                            outcome: .failed, persistence: persistenceOutcomes[key])
        }
    }

    /// Explicit, per-meeting roster fetch. List refreshes never route here.
    func detail(entry: CalendarCLIEntry, config: CalendarCLIConfig, force: Bool) async throws -> CalendarCLIEntry {
        let scope = CalendarCLIScope(config: config)
        guard config.attendeePolicy != .never else {
            throw CalendarCLIServiceError.attendeePolicyForbids
        }
        let startGeneration = generation
        let startRosterGeneration = rosterGeneration

        // A trustworthy count already above the cap short-circuits the read.
        if let count = entry.attendeeCount, count > config.maxAttendees {
            let omitted = CalendarCLIEntry(
                key: entry.key, event: entry.event, sourceRevision: entry.sourceRevision,
                detailsFetchedAt: now(),
                attendeeState: .omittedLargeMeeting,
                attendeeCount: count, isCancelled: entry.isCancelled
            )
            store.storeDetail(scope: scope, entry: omitted)
            return omitted
        }

        if !force {
            if let saved = store.loadDetail(scope: scope, key: entry.key),
               (entry.sourceRevision == nil || saved.sourceRevision == entry.sourceRevision),
               isFresh(saved, config: config, at: now()) {
                let count = saved.attendeeCount ?? saved.event.attendees.count
                if count > config.maxAttendees {
                    return CalendarCLIEntry(key: saved.key,
                        event: saved.event.replacing(attendees: []), sourceRevision: saved.sourceRevision,
                        detailsFetchedAt: saved.detailsFetchedAt, attendeeState: .omittedLargeMeeting,
                        attendeeCount: count, isCancelled: saved.isCancelled)
                }
                if saved.attendeeState != .omittedLargeMeeting { return saved }
            }
            if isFresh(entry, config: config, at: now()),
               entry.event.attendees.count <= config.maxAttendees,
               entry.attendeeState != .omittedLargeMeeting {
                return entry
            }
        }

        let key = Self.rosterKey(scope: scope, key: entry.key, cap: config.maxAttendees)
        let flight: DetailFlight
        if let existing = detailTasks[key] {
            flight = existing
        } else {
            flight = DetailFlight(id: UUID(), task: Task { [transport] in
                try await transport.detail(entry: entry, config: config)
            })
            detailTasks[key] = flight
        }
        defer {
            if detailTasks[key]?.id == flight.id { detailTasks[key] = nil }
        }

        var updated = try await flight.task.value
        try Task.checkCancellation()
        guard generation == startGeneration, rosterGeneration == startRosterGeneration else {
            throw CancellationError()
        }
        guard updated.key == entry.key else {
            throw CalendarCLIServiceError.identityMismatch
        }
        let verifiedCount = updated.attendeeCount ?? updated.event.attendees.count
        if verifiedCount > config.maxAttendees {
            updated = CalendarCLIEntry(key: updated.key,
                event: updated.event.replacing(attendees: []),
                sourceRevision: updated.sourceRevision, detailsFetchedAt: updated.detailsFetchedAt,
                attendeeState: .omittedLargeMeeting, attendeeCount: verifiedCount,
                isCancelled: updated.isCancelled)
        }
        if updated.attendeeState == .loaded || updated.attendeeState == .none
            || updated.attendeeState == .omittedLargeMeeting {
            store.storeDetail(scope: scope, entry: updated)
        }
        return updated
    }

    // MARK: - Lifecycle

    /// Cancels owned in-flight work. Cached files remain; use `clearCache()`
    /// to remove them.
    func invalidate() {
        generation += 1
        listCooldowns = [:]
        memorySnapshots = [:]
        persistenceOutcomes = [:]
        for (_, flight) in listTasks { flight.task.cancel() }
        listTasks = [:]
        for (_, flight) in detailTasks { flight.task.cancel() }
        detailTasks = [:]
    }

    /// Configuration changed: invalidate in-flight results and purge cached
    /// rosters incompatible with the new attendee policy or cap. The purge is
    /// idempotent — it only removes rosters the new rules no longer allow.
    func configurationChanged(_ config: CalendarCLIConfig) async {
        invalidate()
        rosterGeneration += 1
        activeRosterScope = (policy: config.attendeePolicy, cap: config.maxAttendees)
        let scope = CalendarCLIScope(config: config)
        store.purgeRosters(scope: scope, policy: config.attendeePolicy, cap: config.maxAttendees)
    }

    func clearCache() {
        invalidate()
        store.purgeAll()
    }

    /// Last success/attempt stamps for status display.
    func status(scope: CalendarCLIScope, window: CalendarCLIWindow) -> (lastSuccessfulRefresh: Date?, lastAttempt: Date?)? {
        guard let snapshot = cachedSnapshot(scope: scope, window: window) else { return nil }
        return (snapshot.lastSuccessfulRefresh, snapshot.lastAttempt)
    }

    func lastPersistenceOutcome(window: CalendarCLIWindow, config: CalendarCLIConfig) -> CalendarCLIPersistenceOutcome? {
        persistenceOutcomes[Self.taskKey(scope: CalendarCLIScope(config: config), window: window)]
    }

    func lastAttemptOutcome(window: CalendarCLIWindow, config: CalendarCLIConfig) -> ListAttemptOutcome? {
        listAttemptOutcomes[Self.taskKey(scope: CalendarCLIScope(config: config), window: window)]
    }

    /// The settings "Test connection" probe: one bounded read of a tiny
    /// window, reported as completeness. No persistence, no coalescing, no
    /// cooldown side effects, and never a full-resource fetch.
    func probe(window: CalendarCLIWindow, config: CalendarCLIConfig) async -> CalendarCLIListResult {
        do {
            return try await transport.list(window: window, config: config)
        } catch is CancellationError {
            return CalendarCLIListResult(entries: [], completeness: .blocked,
                                         message: "The connection test was cancelled.")
        } catch {
            Logger.calendar.error("Calendar CLI connection test failed: \(error.localizedDescription)")
            return CalendarCLIListResult(entries: [], completeness: .blocked,
                                         message: CalendarCLIProbeFailure.text)
        }
    }

    // MARK: - Staleness

    /// Loaded rosters go stale via the TTL; a differing source revision marks
    /// them stale during refresh reconciliation. Neither path fetches.
    private func markedStale(_ entry: CalendarCLIEntry) -> CalendarCLIEntry {
        CalendarCLIEntry(
            key: entry.key, event: entry.event, sourceRevision: entry.sourceRevision,
            detailsFetchedAt: entry.detailsFetchedAt, attendeeState: .stale,
            attendeeCount: entry.attendeeCount, isCancelled: entry.isCancelled
        )
    }

    private func isFresh(_ entry: CalendarCLIEntry, config: CalendarCLIConfig, at date: Date) -> Bool {
        switch entry.attendeeState {
        case .loaded, .none, .omittedLargeMeeting:
            guard let fetchedAt = entry.detailsFetchedAt else { return false }
            return date.timeIntervalSince(fetchedAt) < TimeInterval(config.detailFreshnessSeconds)
        case .notRequested, .unavailable, .stale:
            return false
        }
    }

    // MARK: - Keys

    private static func taskKey(scope: CalendarCLIScope, window: CalendarCLIWindow) -> String {
        "\(scope.digest)|\(Int(window.start.timeIntervalSince1970))|\(Int(window.end.timeIntervalSince1970))"
    }

    private static func rosterKey(scope: CalendarCLIScope, key: CalendarCLIOccurrenceKey, cap: Int) -> String {
        "\(scope.digest)|\(key.resourceURI)|\(Int(key.occurrenceStart.timeIntervalSince1970))|\(cap)"
    }
}

enum CalendarCLIServiceError: Error, LocalizedError {
    case attendeePolicyForbids
    case identityMismatch
    case refreshFailed

    var errorDescription: String? {
        switch self {
        case .attendeePolicyForbids:
            "Attendee loading is set to Never for the Claude CLI calendar source."
        case .identityMismatch:
            "The fetched roster did not match the requested meeting."
        case .refreshFailed:
            "The calendar list could not be refreshed."
        }
    }
}

/// Bounded failure text for probes: never raw stderr or connector output.
enum CalendarCLIProbeFailure {
    static let text = "The calendar CLI call failed. Check the connection in Settings."
}
