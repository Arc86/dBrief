import Foundation

extension RecordingManager {
    func cachedCalendarMeetingsForLinking(_ recording: Recording) async throws -> CalendarLinkMeetingList {
        try await calendarMeetingsForLinking(recording, refresh: false, force: false)
    }

    func refreshCalendarMeetingsForLinking(_ recording: Recording, force: Bool) async throws -> CalendarLinkMeetingList {
        try await calendarMeetingsForLinking(recording, refresh: true, force: force)
    }

    private func calendarMeetingsForLinking(_ recording: Recording, refresh: Bool,
                                            force: Bool) async throws -> CalendarLinkMeetingList {
        let (start, end) = try await calendarLinkRecordingSpan(recording)
        let events: [CalendarEvent]
        var cliDays: [CalendarCLIListRead] = []
        switch appSettings.effectiveCalendarSource {
        case .iCal:
            guard calendarService.authorizationStatus() == .fullAccess else {
                throw CalendarLinkError.calendarAccess
            }
            events = await calendarService.findEvents(recordingStart: start, recordingEnd: end,
                includeFullRecordingDay: true, selectedCalendarIDs: appSettings.selectedICalCalendarIDs)
        case .outlook:
            events = await outlookCalendarService.findEvents(recordingStart: start, recordingEnd: end,
                includeFullRecordingDay: true)
        case .claudeCLI:
            let config = appSettings.effectiveCalendarCLIConfig
            guard config.isConfigured else { throw CalendarLinkError.calendarAccess }
            let matchWindow = TimeInterval(appSettings.calendarMatchWindowMinutes * 60)
            let windows = Self.calendarCLIDayWindows(from: start, to: end, matchWindow: matchWindow)
            for window in windows {
                let read: CalendarCLIListRead
                if refresh {
                    read = try await calendarCLIService.refreshSnapshot(window: window,
                        config: config, force: force)
                } else {
                    let cached = await calendarCLIService.cachedSnapshot(window: window, config: config)
                    read = config.listFreshnessSeconds == 0
                        ? CalendarCLIListRead(window: cached.window, entries: cached.entries,
                            hasCompleteSnapshot: cached.hasCompleteSnapshot,
                            lastSuccessfulRefresh: cached.lastSuccessfulRefresh,
                            lastAttempt: cached.lastAttempt, outcome: .manualOnly,
                            persistence: cached.persistence)
                        : cached
                }
                cliDays.append(read)
            }
            var unique: [CalendarEvent] = []
            var seen = Set<String>()
            for day in cliDays {
                for entry in day.entries where seen.insert(entry.event.id).inserted {
                    unique.append(entry.event)
                }
            }
            events = unique
        case .disabled:
            throw CalendarLinkError.calendarAccess
        }
        try Task.checkCancellation()
        let matches = CalendarMatcher.rankedMatches(from: events, recordingStart: start, recordingEnd: end,
            fallbackWindow: TimeInterval(appSettings.calendarMatchWindowMinutes * 60))
        let display = CalendarMatcher.displayCandidates(from: events, automaticMatches: matches,
            recordingStart: start, includeFullRecordingDay: true)
        return CalendarLinkMeetingList(recordingStart: start, recordingEnd: end,
                                       events: display, cliDays: cliDays)
    }

    private func calendarLinkRecordingSpan(_ recording: Recording) async throws -> (Date, Date) {
        let audio = recording.finalizedAudioURL ?? recording.fileURL
        let metadata = try await RecordingMetadataStore.shared.load(audioURL: audio)
        let start = metadata.flatMap { ISO8601DateFormatter().date(from: $0.dateISO8601) } ?? recording.date
        let end = start.addingTimeInterval(metadata?.durationSeconds ?? recording.duration)
        return (start, end)
    }

    func linkCalendar(_ event: CalendarEvent, to recording: Recording,
                      updateTitle: Bool, updateParticipants: Bool) async throws {
        let audio = recording.finalizedAudioURL ?? recording.fileURL
        // Only work on this recording conflicts: linking writes its metadata sidecar alone.
        let live = RecordingEligibility.block(for: .linkCalendar, ownership: liveOwnership(for: audio, saved: .init()),
                                              activity: appActivity)
        if let live { throw RecordingBlockedError(block: live) }
        reprocessingAdmissionBusy = true
        defer { reprocessingAdmissionBusy = false }
        if let saved = await savedWorkBlock(for: audio, .linkCalendar) { throw RecordingBlockedError(block: saved) }
        try await RecordingMetadataStore.shared.linkCalendar(event, audioURL: audio,
            updateTitle: updateTitle, updateParticipants: updateParticipants)
        recording.calendarEvent = event
        if updateTitle, !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recording.meetingTitleDraft = event.title
            recording.generatedTitle = event.title
        }
        if updateParticipants { recording.participants = event.attendeeNames }
        calendarContextRevision += 1
        // Existing generated outputs remain available until the user elects to rerun them.
    }
}

private enum CalendarLinkError: LocalizedError {
    case calendarAccess
    var errorDescription: String? {
        String(localized: "Enable calendar integration and allow calendar access in Settings before linking a meeting.")
    }
}
