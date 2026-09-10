import Foundation

extension RecordingManager {
    /// Always query the recording's original day, including when opened from history.
    func calendarEventsForLinking(_ recording: Recording) async throws -> [CalendarEvent] {
        let audio = recording.finalizedAudioURL ?? recording.fileURL
        let metadata = try await RecordingMetadataStore.shared.load(audioURL: audio)
        let start = metadata.flatMap { ISO8601DateFormatter().date(from: $0.dateISO8601) } ?? recording.date
        let end = start.addingTimeInterval(metadata?.durationSeconds ?? recording.duration)
        let events: [CalendarEvent]
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
        case .disabled:
            throw CalendarLinkError.calendarAccess
        }
        try Task.checkCancellation()
        let matches = CalendarMatcher.rankedMatches(from: events, recordingStart: start, recordingEnd: end,
            fallbackWindow: TimeInterval(appSettings.calendarMatchWindowMinutes * 60))
        return CalendarMatcher.displayCandidates(from: events, automaticMatches: matches,
            recordingStart: start, includeFullRecordingDay: true)
    }

    func linkCalendar(_ event: CalendarEvent, to recording: Recording,
                      updateTitle: Bool, updateParticipants: Bool) async throws {
        let audio = recording.finalizedAudioURL ?? recording.fileURL
        guard reprocessingRecoveryReady, !reprocessingAdmissionBusy, !queueMutationInProgress,
              !queueEnqueueInProgress, !queuePauseWriteInProgress, !recoveryMaintenanceInProgress,
              !processingCancellationInProgress, appState.pendingSpeakerReview == nil,
              appState.processingJob == nil, !appState.showPostRecordingSheet else { throw ReprocessingError.busy }
        guard !isReprocessing(audio) else { throw ReprocessingError.pendingAttempt }
        reprocessingAdmissionBusy = true
        defer { reprocessingAdmissionBusy = false }
        guard !(await queueScheduleStore.hasMarker(for: audio)) else { throw ReprocessingError.busy }
        let jobs = await processingJobStore.discover()
        guard jobs.issues.isEmpty, !jobs.jobs.contains(where: {
            $0.status != .completed && $0.dismissedFromQueue != true && $0.source.finalizedAudioPath == audio.path
        }) else { throw ReprocessingError.busy }
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
        "Enable calendar integration and allow calendar access in Settings before linking a meeting."
    }
}
