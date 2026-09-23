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

    private var listTasks: [String: Task<CalendarCLIResult, Error>] = [:]
    private var detailTasks: [String: Task<CalendarCLIEntry, Error>] = [:]

    /// Automatic (non-forced) refreshes back off for this long after a failure.
    static let retryCooldown: TimeInterval = 5 * 60
    private var listCooldowns: [String: Date] = [:]
    private var listAttemptOutcomes: [String: ListAttemptOutcome] = [:]

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

    /// The cached snapshot for the window, however old. Staleness of loaded
    /// rosters is derived here (never persisted) from the TTL because list
    /// responses carry no revision data, and the cap is re-applied on every
    /// read so a lowered cap is respected even before a purge runs.
    func cached(window: CalendarCLIWindow, config: CalendarCLIConfig) async -> [CalendarCLIEntry] {
        let scope = CalendarCLIScope(config: config)
        guard let snapshot = store.loadList(scope: scope, window: window) else { return [] }
        return snapshot.entries.map { adjusted($0, config: config) }
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
        let scope = CalendarCLIScope(config: config)
        let key = Self.taskKey(scope: scope, window: window)
        let startGeneration = generation
        let currentTime = now()

        if !force, config.listFreshnessSeconds == 0 {
            return store.loadList(scope: scope, window: window)?.entries ?? []
        }

        // Automatic triggers honor the retry cooldown; forced refresh bypasses.
        if !force, let cooldownUntil = listCooldowns[key], currentTime < cooldownUntil {
            return store.loadList(scope: scope, window: window)?.entries ?? []
        }

        // Fresh snapshots are returned without a call; only demand (or staleness)
        // reaches the connector.
        let previous = store.loadList(scope: scope, window: window)
        if !force, let lastSuccess = previous?.lastSuccessfulRefresh,
           currentTime.timeIntervalSince(lastSuccess) < TimeInterval(config.listFreshnessSeconds) {
            return previous?.entries ?? []
        }

        // Join already-running work instead of duplicating it.
        if let existing = listTasks[key] {
            let outcome = try await existing.value
            return outcome.completeness == .complete ? outcome.raw : (outcome.previous?.entries ?? [])
        }

        let previousSnapshot = previous
        let task = Task<CalendarCLIResult, Error> { [transport, now] in
            let result = try await transport.list(window: window, config: config)
            let attempt = now()
            var persistedEntries: [CalendarCLIEntry]?
            if result.completeness == .complete {
                persistedEntries = result.entries
            }
            return CalendarCLIResult(entries: persistedEntries, raw: result.entries,
                                     completeness: result.completeness, attempt: attempt,
                                     previous: previousSnapshot)
        }
        listTasks[key] = task
        defer { listTasks[key] = nil }

        do {
            let outcome = try await task.value
            // An old generation may no longer write to the new scope.
            guard generation == startGeneration else { throw CancellationError() }

            if outcome.completeness == .complete {
                listAttemptOutcomes[key] = .complete
                listCooldowns[key] = nil
                store.storeList(CalendarCLIStoredListSnapshot(
                    scope: scope, window: window,
                    entries: outcome.raw,
                    lastSuccessfulRefresh: outcome.attempt,
                    lastAttempt: outcome.attempt
                ))
                reconcileRosterStaleness(scope: scope, stored: previousSnapshot, fresh: outcome.raw, config: config)
                return outcome.raw
            } else {
                listAttemptOutcomes[key] = outcome.completeness == .partial ? .partial : .blocked
                // Partial/blocked: preserve the last complete snapshot.
                store.updateListAttempt(scope: scope, window: window, date: outcome.attempt)
                if outcome.completeness == .blocked {
                    listCooldowns[key] = outcome.attempt.addingTimeInterval(Self.retryCooldown)
                }
                return previousSnapshot?.entries ?? []
            }
        } catch {
            listAttemptOutcomes[key] = .failed
            // A failure keeps the cache and opens the automatic retry cooldown.
            listCooldowns[key] = now().addingTimeInterval(Self.retryCooldown)
            store.updateListAttempt(scope: scope, window: window, date: now())
            throw error
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
                detailsFetchedAt: entry.detailsFetchedAt,
                attendeeState: .omittedLargeMeeting,
                attendeeCount: count, isCancelled: entry.isCancelled
            )
            store.storeDetail(scope: scope, entry: omitted)
            return omitted
        }

        if !force, isFresh(entry, config: config, at: now()) {
            return entry
        }

        let key = Self.rosterKey(scope: scope, key: entry.key, cap: config.maxAttendees)
        if let existing = detailTasks[key] {
            return try await existing.value
        }

        let task = Task<CalendarCLIEntry, Error> { [transport] in
            try await transport.detail(entry: entry, config: config)
        }
        detailTasks[key] = task
        defer { detailTasks[key] = nil }

        let updated = try await task.value
        guard generation == startGeneration, rosterGeneration == startRosterGeneration else {
            throw CancellationError()
        }
        guard updated.key == entry.key else {
            throw CalendarCLIServiceError.identityMismatch
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
        for (_, task) in listTasks { task.cancel() }
        listTasks = [:]
        for (_, task) in detailTasks { task.cancel() }
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
        guard let snapshot = store.loadList(scope: scope, window: window) else { return nil }
        return (snapshot.lastSuccessfulRefresh, snapshot.lastAttempt)
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

    /// During a complete list refresh, a loaded roster whose occurrence now
    /// reports a different revision goes stale without any fetch. Absent
    /// revisions keep the TTL rule handled at read time.
    private func reconcileRosterStaleness(scope: CalendarCLIScope, stored: CalendarCLIStoredListSnapshot?, fresh: [CalendarCLIEntry], config: CalendarCLIConfig) {
        guard let stored, !stored.entries.isEmpty else { return }
        var changed = false
        var entries = stored.entries
        for (index, old) in entries.enumerated() {
            guard old.attendeeState == .loaded else { continue }
            guard let freshEntry = fresh.first(where: { $0.key == old.key }) else { continue }
            if let newRevision = freshEntry.sourceRevision,
               let rosterRevision = old.sourceRevision, newRevision != rosterRevision {
                entries[index] = CalendarCLIEntry(
                    key: old.key, event: old.event, sourceRevision: old.sourceRevision,
                    detailsFetchedAt: old.detailsFetchedAt, attendeeState: .stale,
                    attendeeCount: old.attendeeCount, isCancelled: old.isCancelled
                )
                changed = true
            }
        }
        if changed {
            var snapshot = stored
            snapshot.entries = entries
            store.storeList(snapshot)
        }
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

private struct CalendarCLIResult: Sendable {
    /// Entries eligible to become the new complete snapshot (nil otherwise).
    let entries: [CalendarCLIEntry]?
    let raw: [CalendarCLIEntry]
    let completeness: CalendarCLICompleteness
    let attempt: Date
    let previous: CalendarCLIStoredListSnapshot?
}

enum CalendarCLIServiceError: Error, LocalizedError {
    case attendeePolicyForbids
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .attendeePolicyForbids:
            "Attendee loading is set to Never for the Claude CLI calendar source."
        case .identityMismatch:
            "The fetched roster did not match the requested meeting."
        }
    }
}

/// Bounded failure text for probes: never raw stderr or connector output.
enum CalendarCLIProbeFailure {
    static let text = "The calendar CLI call failed. Check the connection in Settings."
}
