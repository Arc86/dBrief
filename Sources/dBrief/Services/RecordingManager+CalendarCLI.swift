import Foundation
import os

/// Claude CLI calendar lifecycle on RecordingManager: background prefetch
/// after capture start, cache-first candidate lookup at stop, a single routed
/// selection path, and the explicit attendee enrichment action. Capture is
/// never delayed by calendar work; all CLI calls run inside owned tasks.
extension RecordingManager {

    /// Refreshes the selected recording's day list for the post-recording picker.
    /// A cached list remains visible while the connector runs. A selected event
    /// is retained for review if it disappears from a complete new snapshot.
    func refreshCalendarCLIPicker(for recording: Recording, force: Bool) async -> CalendarCLIPickerOutcome {
        guard appSettings.effectiveCalendarSource == .claudeCLI else { return .unconfigured }
        let config = appSettings.calendarCLIConfig
        guard config.isConfigured else { return .unconfigured }
        guard let window = Self.calendarCLIDayWindows(
            from: recording.date, to: recording.date, matchWindow: 0).first else { return .failed }
        let scope = CalendarCLIScope(config: config)
        let before = await calendarCLIService.status(scope: scope, window: window)?.lastSuccessfulRefresh
        let generation = calendarCLIConfigGeneration
        do {
            let entries = try await calendarCLIService.refresh(window: window, config: config, force: force)
            guard appSettings.effectiveCalendarSource == .claudeCLI,
                  calendarCLIConfigGeneration == generation,
                  appSettings.calendarCLIConfig == config else { return .failed }
            let prior = recording.calendarEvent
            let priorKey = prior.flatMap { calendarCLIEntryByEventID[$0.id]?.key }
            var candidates = entries.map(\.event).sorted { $0.startDate < $1.startDate }
            for entry in entries { calendarCLIEntryByEventID[entry.event.id] = entry }
            var selectionMissing = false
            if let prior {
                if let replacement = entries.first(where: { $0.key == priorKey }) {
                    recording.calendarEvent = replacement.event
                } else {
                    selectionMissing = prior.startDate < window.end && prior.endDate > window.start
                    candidates.append(prior)
                }
            }
            recording.calendarCandidates = candidates
            let attemptOutcome = await calendarCLIService.lastAttemptOutcome(window: window, config: config)
            if selectionMissing, force, attemptOutcome == .complete { return .selectionMissing }
            if !force, config.listFreshnessSeconds == 0 { return .manualOnly }
            if force || before == nil || (before.map { Date().timeIntervalSince($0) >= TimeInterval(config.listFreshnessSeconds) } ?? false) {
                switch attemptOutcome {
                case .partial: return .partial
                case .blocked: return .blocked
                case .failed: return .failed
                case .complete, .none: break
                }
            }
            return .complete
        } catch {
            return .failed
        }
    }

    // MARK: - Windows

    /// The local calendar-day windows intersecting `[start, end]` padded by the
    /// match window on both sides. Boundaries come from `Calendar` in the
    /// user's current time zone — never +86400 arithmetic — so DST-short and
    /// DST-long days are represented exactly.
    static func calendarCLIDayWindows(
        from start: Date, to end: Date,
        matchWindow: TimeInterval,
        calendar: Calendar = .current
    ) -> [CalendarCLIWindow] {
        var windows: [CalendarCLIWindow] = []
        var seen = Set<String>()
        let paddedStart = start.addingTimeInterval(-max(0, matchWindow))
        let paddedEnd = end.addingTimeInterval(max(0, matchWindow))
        var cursor = calendar.startOfDay(for: paddedStart)
        while cursor < paddedEnd {
            guard let day = calendar.dateInterval(of: .day, for: cursor) else { break }
            let key = "\(day.start.timeIntervalSince1970)"
            if seen.insert(key).inserted {
                windows.append(CalendarCLIWindow(
                    start: day.start, end: day.end,
                    timeZoneID: calendar.timeZone.identifier
                ))
            }
            cursor = day.end
        }
        return windows
    }

    // MARK: - Prefetch

    /// Launches the owned background prefetch for the capture day. Called only
    /// after capture has successfully started; capture never awaits it.
    func scheduleCalendarCLIPrefetch() {
        guard appSettings.effectiveCalendarSource == .claudeCLI,
              appSettings.calendarCLIConfig.isConfigured else { return }
        let config = appSettings.calendarCLIConfig
        let startedAt = Date()
        let matchWindow = TimeInterval(appSettings.calendarMatchWindowMinutes * 60)
        let windows = Self.calendarCLIDayWindows(from: startedAt, to: startedAt, matchWindow: matchWindow)
        calendarCLIPrefetchTask?.cancel()
        calendarCLIPrefetchTask = Task { [weak self] in
            guard let self else { return }
            for window in windows {
                // The service's TTL gate makes this a fetch only when the
                // snapshot is absent or stale.
                _ = try? await self.calendarCLIService.refresh(
                    window: window, config: config, force: false)
                if Task.isCancelled { return }
            }
        }
    }

    /// Drops the reference to the finished prefetch task.
    func cleanupCalendarCLIPrefetch() {
        calendarCLIPrefetchTask = nil
    }

    // MARK: - Candidate lookup (cache-first)

    /// Events for the recording span from the day snapshots. Reads come from
    /// cache; an absent snapshot triggers one bounded refresh — this runs
    /// inside the recording's `calendarLookupTask`, which processing already
    /// awaits, so the wait is bounded. Errors leave any cached data usable.
    func calendarCLIEvents(recordingStart: Date, recordingEnd: Date) async -> [CalendarEvent] {
        let config = appSettings.calendarCLIConfig
        guard config.isConfigured else { return [] }
        let matchWindow = TimeInterval(appSettings.calendarMatchWindowMinutes * 60)
        let windows = Self.calendarCLIDayWindows(
            from: recordingStart, to: recordingEnd, matchWindow: matchWindow)

        var events: [CalendarEvent] = []
        var seen = Set<String>()
        for window in windows {
            var entries = await calendarCLIService.cached(window: window, config: config)
            if entries.isEmpty {
                entries = (try? await calendarCLIService.refresh(
                    window: window, config: config, force: false)) ?? []
            }
            for entry in entries {
                calendarCLIEntryByEventID[entry.event.id] = entry
                if seen.insert(entry.event.id).inserted {
                    events.append(entry.event)
                }
            }
        }
        return events
    }

    // MARK: - Selection routing

    /// The single selection path for cached metadata: records the pick and
    /// bumps the selection revision. Never fetches anything.
    func selectCalendarCandidate(_ event: CalendarEvent?, for recording: Recording) {
        recording.calendarEvent = event
        recording.calendarSelectionRevision += 1
    }

    // MARK: - Explicit attendee enrichment

    /// The explicit Load/Refresh attendees action. Checks policy, count and
    /// cap first; never runs as a side effect of matching or selection. A
    /// completion applies only when the recording identity, source and
    /// selected occurrence/revision are all unchanged, and both the candidate
    /// and selected event are replaced together (their ids change when the
    /// roster loads). Manual title/participant edits are preserved.
    func loadCalendarCLIAttendees(for recording: Recording) async -> CalendarCLIAttendeeOutcome {
        guard appSettings.effectiveCalendarSource == .claudeCLI else {
            return .sourceInactive
        }
        let config = appSettings.calendarCLIConfig
        guard config.isConfigured else { return .sourceInactive }
        guard config.attendeePolicy == .onDemand else { return .policyForbids }

        guard let selected = recording.calendarEvent,
              let entry = calendarCLIEntryByEventID[selected.id] else {
            return .noOccurrence
        }

        // A trustworthy count already above the cap skips the read entirely.
        if let count = entry.attendeeCount, count > config.maxAttendees,
           entry.attendeeState == .omittedLargeMeeting {
            return .omittedLargeMeeting(count: count)
        }

        let selectionRevision = recording.calendarSelectionRevision
        let generation = calendarCLIConfigGeneration
        let previousNames = selected.attendeeNames
        do {
            let updated = try await calendarCLIService.detail(
                entry: entry, config: config, force: false)
            // Late-completion guards: everything must still line up.
            guard appSettings.effectiveCalendarSource == .claudeCLI,
                  appSettings.calendarCLIConfig == config,
                  generation == calendarCLIConfigGeneration,
                  appState.processingJob?.recording.id != recording.id,
                  recording.calendarSelectionRevision == selectionRevision else {
                return .discarded
            }
            calendarCLIEntryByEventID.removeValue(forKey: selected.id)
            calendarCLIEntryByEventID[updated.event.id] = updated

            // Replace candidate and selected event together: both carry the
            // roster now, and both ids changed.
            recording.calendarCandidates = recording.calendarCandidates.map { candidate in
                candidate.id == selected.id ? updated.event : candidate
            }
            if recording.calendarEvent?.id == selected.id {
                recording.calendarEvent = updated.event
                // Manual edits win: only fill participants when the user has
                // not typed their own list since the roster loaded.
                if recording.participants.isEmpty || recording.participants == previousNames {
                    recording.participants = updated.event.attendeeNames
                }
                calendarContextRevision += 1
            }
            switch updated.attendeeState {
            case .loaded: return .loaded(updated.event.attendees.count)
            case .none: return .noInvitees
            case .omittedLargeMeeting: return .omittedLargeMeeting(count: updated.attendeeCount ?? 0)
            case .unavailable: return .unavailable
            case .stale, .notRequested: return .unavailable
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            Logger.calendar.error("Calendar CLI attendee load failed: \(error.localizedDescription)")
            return .failed
        }
    }

    /// Called when the calendar CLI configuration changes (settings UI).
    /// Invalidates in-flight results and purges rosters the new policy or cap
    /// no longer allows.
    func calendarCLIConfigurationChanged() {
        calendarCLIConfigGeneration += 1
        let config = appSettings.calendarCLIConfig
        Task { [calendarCLIService] in
            await calendarCLIService.configurationChanged(config)
        }
    }

    /// Clears the calendar CLI cache (settings action). Does not touch
    /// metadata already attached to saved recordings.
    func clearCalendarCLICache() {
        Task { [calendarCLIService] in
            await calendarCLIService.clearCache()
        }
    }

    // MARK: - Settings actions

    /// The Test connection action: one bounded read of a tiny window around
    /// now. Reports access — mailbox, connector permission and CLI login —
    /// never merely Claude text generation. Never fetches full resources.
    func testCalendarCLIConnection() async -> CalendarCLIConnectionOutcome {
        let config = appSettings.calendarCLIConfig
        guard config.isConfigured else { return .unconfigured }
        let now = Date()
        let window = CalendarCLIWindow(
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(300),
            timeZoneID: TimeZone.current.identifier
        )
        let result = await calendarCLIService.probe(window: window, config: config)
        switch result.completeness {
        case .complete:
            return .reachable(events: result.entries.count, partial: false)
        case .partial:
            return .reachable(events: result.entries.count, partial: true)
        case .blocked:
            return .blocked
        }
    }

    /// The manual Refresh action: forces the current day's list refresh,
    /// bypassing cooldowns and the freshness gate.
    func refreshCalendarCLINow() async -> CalendarCLIConnectionOutcome {
        let config = appSettings.calendarCLIConfig
        guard config.isConfigured else { return .unconfigured }
        let now = Date()
        let windows = Self.calendarCLIDayWindows(from: now, to: now, matchWindow: 0)
        guard let window = windows.first else { return .failed }
        do {
            let entries = try await calendarCLIService.refresh(
                window: window, config: config, force: true)
            _ = entries
            let cached = await calendarCLIService.cached(window: window, config: config)
            switch await calendarCLIService.lastAttemptOutcome(window: window, config: config) {
            case .complete: return .reachable(events: cached.count, partial: false)
            case .partial: return .reachable(events: cached.count, partial: true)
            case .blocked: return .blocked
            case .failed, .none: return .failed
            }
        } catch {
            Logger.calendar.error("Calendar CLI manual refresh failed: \(error.localizedDescription)")
            return .failed
        }
    }

    /// Current day-list status for the settings display.
    func calendarCLIStatusForToday() async -> (lastSuccessfulRefresh: Date?, lastAttempt: Date?)? {
        let config = appSettings.calendarCLIConfig
        guard config.isConfigured else { return nil }
        let now = Date()
        let windows = Self.calendarCLIDayWindows(from: now, to: now, matchWindow: 0)
        guard let window = windows.first else { return nil }
        return await calendarCLIService.status(
            scope: CalendarCLIScope(config: config), window: window)
    }

    func calendarCLIStatus(for recording: Recording) async -> (lastSuccessfulRefresh: Date?, lastAttempt: Date?)? {
        let config = appSettings.calendarCLIConfig
        guard let window = Self.calendarCLIDayWindows(
            from: recording.date, to: recording.date, matchWindow: 0).first else { return nil }
        return await calendarCLIService.status(scope: CalendarCLIScope(config: config), window: window)
    }
}

enum CalendarCLIConnectionOutcome: Equatable, Sendable {
    case unconfigured
    case reachable(events: Int, partial: Bool)
    case blocked
    case failed
}

enum CalendarCLIPickerOutcome: Equatable, Sendable {
    case complete, manualOnly, partial, blocked, failed, unconfigured, selectionMissing
}

/// Bounded outcomes for the attendee action; no meeting content.
enum CalendarCLIAttendeeOutcome: Equatable, Sendable {
    case loaded(Int)
    case noInvitees
    case omittedLargeMeeting(count: Int)
    case unavailable
    case policyForbids
    case sourceInactive
    case noOccurrence
    case discarded
    case cancelled
    case failed
}
