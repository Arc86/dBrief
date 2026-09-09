import Foundation
import dBriefWire

struct ReprocessingRequest: Codable, Sendable {
    let options: ReprocessingOptions
    let recordingID: UUID
    let date: Date
    let title: String
    let duration: Double
    let participants: [String]
    let calendarEvent: CalendarEvent?
}

enum ReprocessingError: LocalizedError {
    case pendingAttempt, missingAudio, missingTranscript, failedAnalysis, busy, noSpeakers
    var errorDescription: String? {
        switch self {
        case .pendingAttempt: "This recording has unfinished reprocessing. Resume or discard that attempt first."
        case .missingAudio: "The saved audio is unavailable. Reconnect its storage or restore the audio file, then retry."
        case .missingTranscript: "The saved transcript could not be read. Choose Retranscribe to create a replacement from the audio."
        case .failedAnalysis: "Some requested AI results could not be generated. Current results were kept; resume this attempt to retry."
        case .busy: "Finish the active save, review, or cleanup before reprocessing."
        case .noSpeakers: "No speakers were detected. Current results have been kept."
        }
    }
}

extension RecordingManager {
    func invalidateReprocessingChat(_ audio: URL) {
        SpokenSummaryService.invalidateForReprocessing(audioURL: audio)
        TranscriptChatService.invalidateForReprocessing(audioURL: audio)
        transcriptChatStore?.session(for: audio)?.invalidateForReprocessing()
        transcriptChatStore?.remove(for: audio)
    }

    func isReprocessing(_ audioURL: URL) -> Bool {
        reprocessingAttempts.contains { $0.audioURL.standardizedFileURL.resolvingSymlinksInPath() == audioURL.standardizedFileURL.resolvingSymlinksInPath() }
    }

    func lastReprocessingOptions(for recording: Recording) async -> ReprocessingOptions? {
        guard let audio = recording.finalizedAudioURL else { return nil }
        let url = audio.deletingPathExtension().appendingPathExtension("reprocessing.json")
        return await Task.detached {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ReprocessingOptions.self, from: data)
        }.value
    }

    func canRestoreReprocessingResults(for recording: Recording) async -> Bool {
        guard let audio = recording.finalizedAudioURL, !isReprocessing(audio) else { return false }
        return (try? await reprocessingStore.canRestore(audioURL: audio)) == true
    }

    func startReprocessing(for recording: Recording, options: ReprocessingOptions) async throws {
        guard let audio = recording.finalizedAudioURL else { throw ReprocessingError.missingAudio }
        guard reprocessingRecoveryReady, !reprocessingAdmissionBusy, !queueMutationInProgress, !queueEnqueueInProgress, !queuePauseWriteInProgress, !recoveryMaintenanceInProgress,
              !processingCancellationInProgress, appState.pendingSpeakerReview == nil else { throw ReprocessingError.busy }
        if appState.processingJob?.recording.finalizedAudioURL?.resolvingSymlinksInPath() == audio.resolvingSymlinksInPath() {
            throw ReprocessingError.busy
        }
        if appState.showPostRecordingSheet,
           appState.currentRecording?.finalizedAudioURL?.resolvingSymlinksInPath() == audio.resolvingSymlinksInPath() {
            throw ReprocessingError.busy
        }
        try options.validate()
        if options.requiresTranscription { _ = try options.transcriptionSettings(settings: appSettings) }
        if options.requiresAnalysis { _ = try options.analysisConfiguration(settings: appSettings) }
        reprocessingAdmissionBusy = true
        defer { reprocessingAdmissionBusy = false }
        guard !(await queueScheduleStore.hasMarker(for: audio)) else { throw ReprocessingError.busy }
        let existingJobs = await processingJobStore.discover()
        guard existingJobs.issues.isEmpty, !existingJobs.jobs.contains(where: {
            $0.status != .completed && $0.dismissedFromQueue != true && $0.source.finalizedAudioPath == audio.path
        }) else { throw ReprocessingError.busy }
        try Task.checkCancellation()
        let request = ReprocessingRequest(options: options, recordingID: recording.id,
            date: recording.date, title: recording.meetingTitleDraft, duration: recording.duration,
            participants: recording.participants, calendarEvent: recording.calendarEvent)
        let attempt = try await reprocessingStore.prepare(audioURL: audio, configuration: JSONEncoder().encode(request))
        invalidateReprocessingChat(audio)
        reprocessingAttempts.append(attempt)
        reprocessingAdmissionBusy = false
        if appState.processingJob == nil { await resumeReprocessing(attempt.id) }
    }

    func recoverReprocessingAttempts() async {
        guard !reprocessingAdmissionBusy, appState.processingJob == nil else { return }
        reprocessingRecoveryReady = false
        reprocessingAdmissionBusy = true
        defer { reprocessingAdmissionBusy = false }
        do {
            let attempts = try await reprocessingStore.recover()
            // An interrupted stage is offered explicitly, never silently repeated.
            for attempt in attempts where attempt.status != .completed && attempt.status != .queued
                && attempt.status != .stopped && attempt.status != .failed {
                try await reprocessingStore.checkpoint(attemptID: attempt.id, status: .stopped,
                    message: "Interrupted reprocessing — current results have been kept.")
            }
            reprocessingRecoveryReady = true
            reprocessingResultsRevision += 1
            await refreshReprocessingAttempts()
        } catch {
            reprocessingRecoveryReady = false
            appState.lastError = "Reprocessing recovery needs attention: \(error.localizedDescription)"
        }
    }

    func refreshReprocessingAttempts() async {
        do {
            reprocessingAttempts = try await reprocessingStore.discover().filter { $0.status != .completed }
        } catch {
            reprocessingRecoveryReady = false
            appState.lastError = error.localizedDescription
        }
    }

    func drainReprocessingQueue() async {
        guard reprocessingRecoveryReady, appState.processingJob == nil, !queuePaused, !reprocessingAdmissionBusy else { return }
        await refreshReprocessingAttempts()
        for next in reprocessingAttempts.filter({ $0.status == .queued }).sorted(by: { $0.createdAt < $1.createdAt }) {
            guard reprocessingRecoveryReady, appState.processingJob == nil, !queuePaused else { return }
            await resumeReprocessing(next.id)
        }
    }

    func resumeReprocessing(_ id: UUID) async {
        guard reprocessingRecoveryReady, !reprocessingAdmissionBusy, appState.processingJob == nil else { return }
        reprocessingAdmissionBusy = true
        defer { reprocessingAdmissionBusy = false }
        do {
            let attempt = try await reprocessingStore.load(attemptID: id)
            guard attempt.status != .completed else { return }
            try await reprocessingStore.validate(attemptID: id)
            let request = try JSONDecoder().decode(ReprocessingRequest.self, from: attempt.configuration)
            if request.options.requiresTranscription && !attempt.completedStages.contains("transcription") { _ = try request.options.transcriptionSettings(settings: appSettings) }
            if request.options.requiresAnalysis && !attempt.completedStages.contains("analysis") { _ = try request.options.analysisConfiguration(settings: appSettings) }
            let working = Recording(id: request.recordingID, date: request.date, fileURL: attempt.audioURL,
                duration: request.duration, meetingTitleDraft: request.title, finalizedAudioURL: attempt.audioURL)
            working.participants = request.participants
            working.calendarEvent = request.calendarEvent
            try Task.checkCancellation()
            reprocessingAdmissionBusy = false
            guard canLaunchProcessing(for: working, reprocessingAttemptID: id) else { throw ReprocessingError.busy }
            appState.processingSteps = []
            appState.preflightWarning = nil
            appState.liveInferenceText = nil
            let job = launchJob(id: id, recording: working, reprocessingAttemptID: id) { job in
                await self.runReprocessing(job, request: request)
            }
            job.reprocessingAttemptID = id
        } catch {
            try? await reprocessingStore.checkpoint(attemptID: id, status: Task.isCancelled ? .stopped : .failed,
                message: error.localizedDescription)
            appState.lastError = error.localizedDescription
            await refreshReprocessingAttempts()
        }
    }

    func runReprocessing(_ job: ProcessingJob, request: ReprocessingRequest) async {
        let store = reprocessingStore
        do {
            try requireProcessingOwnership(job)
            let attempt = try await store.load(attemptID: job.id)
            try await hydrateReprocessing(job, options: request.options)
            let options = request.options
            var stages: [ReprocessingWorkflow.Stage] = []
            if options.requiresTranscription { stages.append(.transcription) }
            if options.requiresSpeakers { stages.append(.speakers) }
            if options.requiresAnalysis { stages.append(.analysis) }
            let completed = Set(attempt.completedStages.compactMap(ReprocessingWorkflow.Stage.init(rawValue:)))
            let result = try await ReprocessingWorkflow.run(stages: stages, completed: completed,
                execute: { @MainActor stage in
                    try self.requireProcessingOwnership(job)
                    let status: ReprocessingStore.Status = switch stage {
                    case .transcription: .transcribing
                    case .speakers: .speakers
                    case .analysis: .analysis
                    }
                    try await store.checkpoint(attemptID: job.id, status: status)
                    return try await self.executeReprocessing(stage, job: job, options: options)
                }, checkpoint: { @MainActor stage in
                    try self.requireProcessingOwnership(job)
                    try await store.checkpoint(attemptID: job.id, status: .ready, completedStage: stage.rawValue)
                }, publish: { @MainActor in
                    try self.requireProcessingOwnership(job)
                    if options.retainedAnalysisIsStale || options.operation == .speakers {
                        if let data = try await store.originalData(suffix: "insights.json", attemptID: job.id) {
                            var insights = try JSONDecoder().decode(RecordingInsights.self, from: data)
                            insights.basedOnPreviousTranscript = true
                            // Explicit export only: an old link must not cause subsequent edits to overwrite that note.
                            insights.markdownPath = nil
                            try await store.stage(JSONEncoder().encode(insights), suffix: "insights.json", attemptID: job.id)
                        }
                    }
                    for suffix in ["chat.json", "spokensummary.json", "spokensummary.m4a"] {
                        try await store.stageRemoval(suffix: suffix, attemptID: job.id)
                    }
                    var provenance = options
                    provenance.completion = ProcessingCompletionStamp(jobID: job.id, completedAt: Date())
                    try await store.stage(JSONEncoder().encode(provenance), suffix: "reprocessing.json", attemptID: job.id)
                    try self.requireProcessingOwnership(job)
                    self.reprocessingRecoveryReady = false
                    try await store.commit(attemptID: job.id)
                    self.reprocessingRecoveryReady = true
                    self.reprocessingResultsRevision += 1
                    RecordingLibraryChange.notify()
                }, validate: { @MainActor in try self.requireProcessingOwnership(job) })
            if result == .held { await refreshReprocessingAttempts(); return }
            await endReprocessing(job)
        } catch {
            // Once publication begins, reconcile its journal before exposing results.
            // Cancellation cannot roll back a partially published set.
            if !reprocessingRecoveryReady {
                do {
                    _ = try await store.recover()
                    reprocessingRecoveryReady = true
                    reprocessingResultsRevision += 1
                    RecordingLibraryChange.notify()
                } catch { appState.lastError = "Reprocessing recovery needs attention: \(error.localizedDescription)" }
            }
            let stopped = Task.isCancelled
            try? await store.checkpoint(attemptID: job.id, status: stopped ? .stopped : .failed,
                message: stopped ? "Stopped — current results have been kept." : error.localizedDescription)
            if !stopped, appState.processingJob === job {
                appState.lastError = error.localizedDescription
                appState.processingSteps.append(.init(name: "Reprocessing", status: .failed(error.localizedDescription)))
                await endReprocessing(job)
            }
        }
    }

    func endReprocessing(_ job: ProcessingJob) async {
        guard appState.processingJob === job else { return }
        appState.processingJob = nil
        await refreshWorkQueue()
        await drainQueueIfNeeded()
        await drainReprocessingQueue()
    }

    func stopReprocessing(_ job: ProcessingJob) async {
        guard !processingCancellationInProgress, appState.processingJob === job else { return }
        processingCancellationInProgress = true
        defer { processingCancellationInProgress = false }
        job.task?.cancel()
        if appState.pendingSpeakerReview?.recording === job.recording {
            appState.pendingSpeakerReview = nil
            SpeakerReviewWindowController.shared.dismissForCancelledJob()
        }
        await forceReleaseGPU()
        await job.task?.value
        try? await reprocessingStore.checkpoint(attemptID: job.id, status: .stopped,
            message: "Stopped — current results have been kept.")
        if appState.processingJob === job { appState.processingJob = nil }
        await refreshWorkQueue()
    }

    func discardReprocessing(_ id: UUID) async {
        guard appState.processingJob?.reprocessingAttemptID != id, !reprocessingAdmissionBusy else { return }
        reprocessingAdmissionBusy = true
        defer { reprocessingAdmissionBusy = false }
        do {
            try await reprocessingStore.discard(attemptID: id)
            reprocessingResultsRevision += 1
            await refreshWorkQueue()
        }
        catch { appState.lastError = error.localizedDescription }
    }

    func restoreReprocessingResults(for recording: Recording) async throws {
        guard let audio = recording.finalizedAudioURL else { throw ReprocessingError.missingAudio }
        guard canLaunchProcessing(for: recording), !reprocessingAdmissionBusy, !isReprocessing(audio) else {
            throw ReprocessingError.busy
        }
        reprocessingAdmissionBusy = true
        defer { reprocessingAdmissionBusy = false }
        invalidateReprocessingChat(audio)
        reprocessingRecoveryReady = false
        do {
            try await reprocessingStore.restore(audioURL: audio)
            reprocessingRecoveryReady = true
        } catch {
            do { _ = try await reprocessingStore.recover(); reprocessingRecoveryReady = true }
            catch { appState.lastError = "Reprocessing recovery needs attention: \(error.localizedDescription)" }
            reprocessingResultsRevision += 1
            throw error
        }
        reprocessingResultsRevision += 1
        RecordingLibraryChange.notify()
        await refreshReprocessingAttempts()
    }
}
