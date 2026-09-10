
import Foundation
import dBriefWire
import AppKit
import AVFoundation
import UserNotifications
import UniformTypeIdentifiers
import OSLog

@MainActor
@Observable
final class RecordingManager {
    let appState: AppState
    let appSettings: AppSettings
    @ObservationIgnored private lazy var captureCoordinator = CaptureCoordinator(
        hardware: .live(AudioCaptureManager()), persistence: .live(captureSessionStore),
        onEvent: { [weak self] event in self?.applyCaptureEvent(event) })
    @ObservationIgnored private lazy var recordingReviewSlot = RecordingReviewSlot(
        appState: appState, action: postRecordingAction,
        captureBusy: { [weak self] in self?.captureCoordinator.isBusy ?? true },
        maintenance: { [weak self] in self?.recoveryMaintenanceInProgress ?? true })
    private let transcriptionService = TranscriptionService()
    private let localTranscriptionService = LocalTranscriptionService()
    /// One supervised helper process backs both local-ML proxies, so they share
    /// the GPU-serializing orchestrator inside dBriefMLHost.
    private let mlHost = MLHostConnection(
        binaryURL: MLHostLocator.binaryURL(),
        supportBase: MLHostLocator.supportBase())
    let localAIPluginService: LocalAIPluginService
    let parakeetService: ParakeetTranscriptionService
    /// Exposed for TranscriptChatService — read-only reference; access serialized by the helper's AsyncMutex.
    var localPlugin: LocalAIPluginService { localAIPluginService }
    var miniPlayer: FloatingMiniPlayerController?
    /// Set by the manual "Process Queue" button so the drain chain also processes
    /// user-deferred items (not just auto-queued overflow); reset once the queue is drained.
    private var drainAllQueued = false
    let queueScheduleStore: QueueScheduleStore
    var queueEnqueueInProgress = false
    private var queueDrainInProgress = false
    private var queueDrainRequested = false
    private var queuePauseGeneration = 0
    var queuePauseWriteInProgress = false
    var queuePaused = false
    private var queueSafetyHold = false
    var queueMutationInProgress = false
    var recoveryMaintenanceInProgress = false
    var processingCancellationInProgress = false
    private var processingCancellationID: UUID?
    private var speakerReviewOperation: ReviewOperation?
    let postRecordingAction = PostRecordingActionState()
    let postRecordingAutomation = PostRecordingAutomation()
    private var postRecordingAutomationTask: Task<Void, Never>?
    private var profileSelectionTask: Task<Void, Never>?
    var pendingQueueItems: [QueueScheduleStore.Entry] = []
    var recoveryQueueEntries: [RecoveryQueueEntry] = []
    let reprocessingStore: ReprocessingStore
    weak var transcriptChatStore: TranscriptChatStore?
    var reprocessingAttempts: [ReprocessingStore.Attempt] = []
    var reprocessingResultsRevision = 0
    var calendarContextRevision = 0
    var reprocessingAdmissionBusy = false
    var reprocessingRecoveryReady = true
    var queueLoadError: String?
    private var queueRefreshGeneration = 0
    /// Forward the coordinator's observable phases to existing Settings callers.
    var modelDownloads: [LocalModelKind: ModelDownloadPhase] { modelDownloadCoordinator.phases }
    private let modelDownloadCoordinator: ModelDownloadCoordinator
    let aiService = AIService()
    let localCLIService = LocalCLIService()
    private let integrationDispatchService = IntegrationDispatchService()
    private let integrationDeliveryStore: IntegrationDeliveryStore
    @ObservationIgnored private lazy var integrationDeliveryCoordinator = IntegrationDeliveryCoordinator(store: integrationDeliveryStore)
    var reviewingIntegrationDeliveries = false
    private let recordingFinalizer = RecordingFinalizer()
    let transcriptStore: TranscriptStore
    let insightsStore: InsightsStore
    private let markdownOutputStore = MarkdownOutputStore()
    let voiceLibraryStore: VoiceLibraryStore
    private let modelPerformanceStore: ModelPerformanceStore
    let processingJobStore: ProcessingJobStore
    let processingPipeline: ProcessingPipeline
    private let importCoordinator: ImportCoordinator
    private let captureSessionStore: CaptureSessionStore
    @ObservationIgnored private var pickedImportTask: Task<Void, Never>?
    @ObservationIgnored private var pickedImportGeneration = 0
    let calendarService = CalendarService()
    private let microsoftAuthService: MicrosoftAuthService
    let outlookCalendarService: OutlookCalendarService

    // Memory requirements for local models (bytes)
    private enum MemoryThreshold {
        static let gemma4_e4b: Int64 = 4_800_000_000  // ~4.8 GB
    }

    init(
        appState: AppState,
        appSettings: AppSettings,
        transcriptStore: TranscriptStore,
        insightsStore: InsightsStore,
        voiceLibraryStore: VoiceLibraryStore,
        modelPerformanceStore: ModelPerformanceStore,
        processingJobStore: ProcessingJobStore,
        microsoftAuthService: MicrosoftAuthService,
        importCoordinator: ImportCoordinator = ImportCoordinator(),
        modelDownloadCoordinator: ModelDownloadCoordinator? = nil,
        processingPipeline: ProcessingPipeline = ProcessingPipeline(),
        captureSessionStore: CaptureSessionStore = CaptureSessionStore(),
        reprocessingStore: ReprocessingStore = ReprocessingStore(),
        queueScheduleStore: QueueScheduleStore = QueueScheduleStore(),
        integrationDeliveryStore: IntegrationDeliveryStore = IntegrationDeliveryStore()
    ) {
        self.queueScheduleStore = queueScheduleStore
        self.integrationDeliveryStore = integrationDeliveryStore
        self.reprocessingStore = reprocessingStore
        self.processingPipeline = processingPipeline
        self.captureSessionStore = captureSessionStore
        self.importCoordinator = importCoordinator
        self.appState = appState
        self.appSettings = appSettings
        self.transcriptStore = transcriptStore
        self.insightsStore = insightsStore
        self.voiceLibraryStore = voiceLibraryStore
        self.modelPerformanceStore = modelPerformanceStore
        self.processingJobStore = processingJobStore
        self.microsoftAuthService = microsoftAuthService
        self.outlookCalendarService = OutlookCalendarService(authService: microsoftAuthService)
        self.localAIPluginService = LocalAIPluginService(connection: mlHost)
        self.parakeetService = ParakeetTranscriptionService(connection: mlHost)
        self.modelDownloadCoordinator = modelDownloadCoordinator ?? ModelDownloadCoordinator(
            dependencies: .live(plugin: self.localAIPluginService, parakeet: self.parakeetService))
    }

    /// Returns a PreflightWarning if the given engine requires more memory than is available.
    /// Returns nil if memory is sufficient or the engine is remote (no check needed).
    static func preflightCheck(
        engine: AppSettings.AIEngine,
        hasRemoteEndpoint: Bool
    ) -> PreflightWarning? {
        let required: Int64
        let modelName: String
        switch engine {
        case .qwenLocal:
            required = MemoryThreshold.gemma4_e4b
            modelName = "Gemma 4 E4B (Local)"
        case .appleIntelligence, .remoteEndpoint, .localCLI:
            return nil   // no local model loaded
        }
        guard !MemoryPressureMonitor.hasSufficientMemory(requiredBytes: required) else { return nil }
        let stats = MemoryPressureMonitor.getMemoryStats()
        let available = stats.map { Double($0.free) / 1_073_741_824 } ?? 0
        return PreflightWarning(
            modelName: modelName,
            requiredGB: Double(required) / 1_073_741_824,
            availableGB: available,
            hasRemoteEndpoint: hasRemoteEndpoint
        )
    }

    func checkPermissions() async {
        captureCoordinator.refreshPermissions()
    }

    func refreshPermissions() {
        captureCoordinator.refreshPermissions()
    }

    @discardableResult
    func requestMicrophonePermission() async -> Bool {
        await captureCoordinator.requestMicrophonePermission()
    }

    var hasSystemAudioPermission: Bool { captureCoordinator.hasSystemAudioPermission }
    var hasMicrophonePermission: Bool { captureCoordinator.hasMicrophonePermission }
    var microphoneAuthorizationState: PermissionAuthorizationState {
        captureCoordinator.microphoneAuthorizationState
    }
    var hasActiveProcessingJob: Bool { appState.processingJob != nil || processingCancellationInProgress }

    /// Promotes any interrupted Application Support capture into the normal
    /// recordings library. Recovery never starts transcription or integrations;
    /// it only makes the audio durable and visible in History.
    @discardableResult
    func recoverInterruptedSessions(only sessionID: UUID? = nil) async -> Bool {
        guard canPerformLibraryWork else { return false }
        recoveryMaintenanceInProgress = true
        defer { recoveryMaintenanceInProgress = false }
        let report: CaptureSessionStore.RecoveryReport
        do {
            report = try await captureSessionStore.recoverInterrupted(only: sessionID) { @MainActor [weak self] input in
                guard let self else { throw CancellationError() }
                try Task.checkCancellation()
                let candidate = input.candidate
                let recording = Recording(id: candidate.manifest.id, date: candidate.manifest.startedAt,
                    fileURL: candidate.manifestURL.deletingLastPathComponent().appendingPathComponent("capture"),
                    meetingTitleDraft: "Recovered recording")
                recording.capturedTracks = candidate.capturedTracks
                recording.recoveryManifestURL = candidate.manifestURL
                recording.fileSize = input.fileSize
                recording.duration = input.duration
                try await self.ensureRecordingFinalized(recording: recording)
                return recording.fileURL
            }
            try Task.checkCancellation()
        } catch {
            // Ordinary session failures are counted by the actor. Cancellation
            // must not become a recovery-failure notice or publish stale success.
            return false
        }
        guard report.recovered + report.failed > 0 else { return false }
        let recoveredCount = report.recovered
        let failedCount = report.failed

        if failedCount == 0 {
            appState.durabilityNoticeIsWarning = false
            appState.durabilityNotice = recoveredCount == 1
                ? "Recovered an interrupted recording. It is available in History."
                : "Recovered \(recoveredCount) interrupted recordings. They are available in History."
        } else {
            appState.durabilityNoticeIsWarning = true
            appState.durabilityNotice = "Recovered \(recoveredCount) recording(s). \(failedCount) session(s) remain safe in Recording Recovery; reconnect the configured storage and retry recovery."
        }
        return failedCount == 0
    }

    /// Resumes at most one interrupted job through durable Markdown export.
    /// Integration delivery remains outside automatic replay.
    func resumeInterruptedProcessingJob() async {
        guard appState.processingJob == nil, !recoveryMaintenanceInProgress, !queueMutationInProgress else { return }
        queueMutationInProgress = true
        defer { queueMutationInProgress = false }
        let pauseGeneration = queuePauseGeneration
        do {
            queuePaused = try await queueScheduleStore.load().paused
            guard !queuePaused else { return }
        } catch {
            queueLoadError = "Saved queue settings could not be read. Automatic recovery is paused."
            return
        }
        let discovery = await processingJobStore.discover()

        if !discovery.issues.isEmpty {
            appState.durabilityNoticeIsWarning = true
            appState.durabilityNotice = "Some saved processing jobs could not be read and were left untouched."
        }

        for var record in discovery.jobs {
            switch record.launchRecoveryAction {
            case .none:
                continue
            case .parkAtMarkdownBoundary:
                record.markMarkdownBoundaryReached(at: Date())
                do {
                    try await processingJobStore.save(record)
                    if let path = record.source.finalizedAudioPath {
                        let audioURL = URL(fileURLWithPath: path)
                        try? await queueScheduleStore.retireItem(at: audioURL, expectedID: record.id)
                    }
                } catch {
                    appState.durabilityNoticeIsWarning = true
                    appState.durabilityNotice = "Saved Markdown was found, but its recovery checkpoint could not be updated. Its files were left untouched."
                }
                continue
            case .resumeToMarkdownBoundary:
                break
            }

            let recovered: Recording?
            do { recovered = try await recordingForRecovery(record) }
            catch { return } // Cancellation must never become a missing-input checkpoint.
            guard let recording = recovered else {
                record.markFailed(.missingInput, at: Date())
                try? await processingJobStore.save(record)
                appState.durabilityNoticeIsWarning = true
                appState.durabilityNotice = "A saved processing job could not find its recording. Its recovery data was left untouched."
                continue
            }

            updatePersistedSource(&record.source, from: recording)
            var queuedAudioURL: URL?
            if let audio = recording.finalizedAudioURL, await queueScheduleStore.hasMarker(for: audio) {
                queuedAudioURL = audio
            }
            guard !Task.isCancelled, appState.processingJob == nil,
                  !processingCancellationInProgress, !recoveryMaintenanceInProgress,
                  !reviewingIntegrationDeliveries, !queueSafetyHold, !queuePauseWriteInProgress,
                  !queueEnqueueInProgress, pauseGeneration == queuePauseGeneration else { return }
            queueMutationInProgress = false // Synchronous admission handoff to launchJob.
            appState.durabilityNoticeIsWarning = false
            appState.durabilityNotice = "Resuming interrupted audio processing."
            let request = record.request
            launchJob(
                recording: recording,
                queuedAudioURL: queuedAudioURL,
                existingRecord: record
            ) { job in
                if record.checkpoint.hasCompleted(.analyzed) {
                    await self.resumeExport(job: job)
                    return
                }
                await self.processRecording(
                    job: job,
                    transcribe: request.transcribe,
                    summary: request.summary,
                    actionItems: request.actionItems,
                    tags: request.tags,
                    stopBeforeIntegrations: true
                )
            }
            return
        }
    }

    /// Analyzed jobs need no finalization, transcription, or speaker processing.
    /// A frozen export can finish even when earlier stage sidecars were moved.
    private func resumeExport(job: ProcessingJob) async {
        guard !Task.isCancelled, appState.processingJob === job,
              let record = job.persistedRecord else { return }
        appState.processingSteps = []
        appState.liveInferenceText = nil
        let recording = job.recording
        let input = recoveryInputRequest(for: recording,
            mode: .export(hasFrozenPlan: record.markdownExport != nil, transcribe: record.request.transcribe))
        let store = transcriptStore
        do {
            let loaded = try await processingPipeline.recoverInputs(input, loadRich: { try await store.load(from: $0) },
                validateOwnership: { @MainActor in
                    try self.requireProcessingOwnership(job)
                    try self.requireRecoveryInputPaths(input, recording: recording)
                })
            try requireProcessingOwnership(job)
            try requireRecoveryInputPaths(input, recording: recording)
            if let loaded {
                recording.transcription = loaded.transcription
                recording.richTranscript = loaded.richTranscript
                if let url = loaded.loadedTranscriptURL { recording.transcriptURL = url }
            }
        } catch {
            guard !Task.isCancelled, appState.processingJob === job else { return }
            appState.processingSteps.append(ProcessingStep(
                name: "Loading saved transcript", status: .failed(error.localizedDescription)))
            await markPersistedJobFailed(.missingInput, job: job)
            await ensureRetryQueue(for: job)
            guard !Task.isCancelled, appState.processingJob === job else { return }
            await finishJob(job, completed: false)
            return
        }
        guard !Task.isCancelled, appState.processingJob === job else { return }
        await runAnalysisAndExport(
            recording: job.recording, transcribe: record.request.transcribe,
            summary: record.request.summary, actionItems: record.request.actionItems,
            tags: record.request.tags, localAIAvailable: false,
            perf: TranscriptionPerf(), stopBeforeIntegrations: true
        )
    }

    private func recordingForRecovery(_ record: PersistedProcessingJob) async throws -> Recording? {
        let recovered = try await processingPipeline.recoverRecordingSource(recordingID: record.recordingID,
            source: record.source, recordingFolder: appSettings.effectiveRecordingFolderURL,
            recoveryRoot: InterruptedSessionStore.defaultRootURL)
        try Task.checkCancellation()
        guard let source = recovered else { return nil }
        let recording = Recording(id: record.recordingID, date: record.source.recordingDate,
            fileURL: source.fileURL, duration: source.duration, fileSize: source.fileSize,
            associatedApp: record.source.associatedApp, meetingTitleDraft: record.source.meetingTitle,
            finalizedAudioURL: source.finalizedAudioURL, segmentAudioURLs: source.segmentAudioURLs,
            metadataURL: source.metadataURL)
        recording.importSourceURL = source.importSourceURL
        recording.capturedTracks = source.capturedTracks
        recording.recoveryManifestURL = source.recoveryManifestURL
        recording.participants = record.source.participants
        recording.calendarEvent = record.source.calendarEvent
        recording.echoSuppressionApplied = record.source.echoSuppressionApplied
        recording.titleWasUserProvided = record.request.titleWasUserProvided
        return recording
    }

    /// Closes an active audio file before AppDelegate's hard process exit. The
    /// durable manifest stays recoverable and is finalized on next launch.
    func prepareForTermination() async {
        cancelPostRecordingAutomation()
        await captureCoordinator.stop(terminating: true)
    }

    func startRecording(associatedApp: String? = nil, callBundleId: String? = nil) async throws {
        guard !captureCoordinator.isBusy else { throw CaptureCoordinator.Failure.busy }
        guard !postRecordingAction.isBusy else {
            throw NSError(domain: "RecordingManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wait for the current recording to finish saving before recording again."])
        }
        guard !recoveryMaintenanceInProgress else {
            throw NSError(domain: "RecordingManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wait for recording cleanup to finish before recording."])
        }
        cancelPostRecordingAutomation()
        if appState.processingJob == nil, let owner = appSettings.automaticProfileRecordingID {
            appSettings.finishAutomaticRouting(for: owner)
        }
        cancelAllActiveDownloads()
        let recordingID = UUID()
        let request = CaptureCoordinator.Request(id: recordingID, startedAt: Date(),
            inputDeviceUID: appSettings.audioInputDeviceUID,
            acousticEchoCancellation: appSettings.acousticEchoCancellation,
            echoSuppression: appSettings.acousticEchoCancellation && AudioOutputRoute.currentOutputHasEchoPath(),
            liveTranscription: appSettings.liveTranscriptionEnabled, language: appSettings.effectiveTranscriptionLanguage,
            associatedApp: associatedApp, callBundleID: callBundleId, showMiniPlayer: appSettings.showMiniRecordingView,
            prewarmWhisper: appSettings.effectiveTranscriptionEngine == .localWhisper ? appSettings.whisperRuntimeConfig : nil,
            privacyScope: RecordingPrivacyScope(recordingID: recordingID))
        try await captureCoordinator.start(request)
    }

    /// Invoked synchronously while the coordinator still owns admission. Storage
    /// and hardware teardown have already settled before a terminal UI handoff.
    private func applyCaptureEvent(_ event: CaptureCoordinator.Event) {
        switch event {
        case .prepared(let request, let session):
            let recording = Recording(id: request.id, date: request.startedAt, fileURL: session.files.captureBaseURL,
                associatedApp: request.associatedApp, meetingTitleDraft: defaultMeetingTitle(from: request.associatedApp))
            recording.recoveryManifestURL = session.files.manifestURL
            recording.privacyScope = request.privacyScope
            recording.echoSuppressionApplied = request.echoSuppression
            appState.currentRecording = recording
            appState.callRecordingBundleId = request.callBundleID
            appState.showPostRecordingSheet = false
        case .started(let request):
            guard appState.currentRecording?.id == request.id else { return }
            appState.recordingState = .recording
            if let config = request.prewarmWhisper {
                Task { await localAIPluginService.prewarmWhisper(config: config, refresh: false) }
            }
            if request.showMiniPlayer { miniPlayer?.show() }
        case .paused(let id):
            guard appState.currentRecording?.id == id else { return }
            appState.recordingState = .paused
        case .resumed(let id):
            guard appState.currentRecording?.id == id else { return }
            appState.recordingState = .recording
        case .meter(let id, let duration, let peak):
            guard appState.currentRecording?.id == id else { return }
            appState.peakLevel = peak
            if Int(duration) != Int(appState.recordingDuration) { appState.recordingDuration = duration }
        case .status(let id, let note):
            guard appState.currentRecording?.id == id else { return }
            appState.recordingStatusNote = note
        case .liveBegan(let id):
            guard appState.currentRecording?.id == id else { return }
            appState.liveTranscriptSegments = []
            appState.liveVolatileMic = ""
            appState.liveVolatileSystem = ""
            appState.liveStatusMessage = ""
            appState.isLiveTranscribing = true
        case .liveEnded(let id):
            guard appState.currentRecording?.id == id else { return }
            appState.isLiveTranscribing = false
            appState.liveVolatileMic = ""
            appState.liveVolatileSystem = ""
            appState.liveStatusMessage = ""
        case .live(let id, let event):
            guard appState.currentRecording?.id == id else { return }
            switch event {
            case .finalized(let segments):
                appState.liveStatusMessage = ""
                appState.liveTranscriptSegments = LiveSegmentMerge.insert(segments, into: appState.liveTranscriptSegments)
            case .volatile(let speaker, let text):
                if !text.isEmpty { appState.liveStatusMessage = "" }
                if speaker == LiveTranscriptionService.Channel.mic.rawValue { appState.liveVolatileMic = text }
                else { appState.liveVolatileSystem = text }
            case .status(let message): appState.liveStatusMessage = message
            }
        case .stopped(let result, let terminating):
            appState.recordingStatusNote = nil
            guard let recording = appState.currentRecording, recording.id == result.session.id else { return }
            recording.capturedTracks = result.state.tracks
            recording.finalizedAudioURL = nil
            recording.segmentAudioURLs = []
            recording.metadataURL = nil
            recording.finalizationWarnings = []
            recording.fileSize = result.fileSize
            recording.duration = result.duration
            appState.recordingState = .idle
            appState.callRecordingBundleId = nil
            miniPlayer?.dismiss()
            guard !terminating else { return }
            if result.fileSize == 0 {
                appState.lastError = "No audio was written. The recovery session was kept so this failure can be investigated."
            }
            if recording.meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recording.meetingTitleDraft = defaultMeetingTitle(from: recording.associatedApp)
            }
            if appSettings.effectiveCalendarSource != .disabled {
                recording.calendarLookupTask = Task { [weak self, weak recording] in
                    guard let self, let recording else { return }
                    await self.lookupCalendarCandidates(for: recording)
                }
            }
            appState.showPostRecordingSheet = true
            schedulePostRecordingProfileSelection()
        case .failed(let id):
            guard appState.currentRecording?.id == id else { return }
            appState.recordingStatusNote = nil
            appState.currentRecording = nil
            appState.callRecordingBundleId = nil
            appState.recordingState = .idle
            miniPlayer?.dismiss()
        }
    }

    func stopRecording() async {
        await captureCoordinator.stop()
    }

    func cancelPostRecordingAutomation(manualOverride: Bool = true) {
        postRecordingAutomationTask?.cancel()
        postRecordingAutomationTask = nil
        postRecordingAutomation.cancel()
        if manualOverride {
            profileSelectionTask?.cancel()
            profileSelectionTask = nil
            appState.currentRecording?.awaitingProfileContext = false
            if let recording = appState.currentRecording {
                if recording.profileSelection.isManual {
                    _ = recording.profileSelection.retainedManualChoice(savedManualID: appSettings.activeProfileId)
                } else {
                    recording.profileSelection.chooseManually(recording.profileSelection.reviewProfileID(savedManualID: appSettings.activeProfileId),
                        savedManualID: appSettings.activeProfileId)
                }
            }
        }
    }

    private func schedulePostRecordingProfileSelection() {
        cancelPostRecordingAutomation(manualOverride: false)
        profileSelectionTask?.cancel()
        guard let recording = appState.currentRecording else { return }
        // Capture the fallback before any asynchronous context arrives.
        recording.profileSelection = RecordingProfileSelection(baselineID: appSettings.activeProfileId)
        guard appSettings.profiles.contains(where: { $0.automaticMatchingEnabled && !$0.matchingRules.isEmpty }) else {
            refreshPostRecordingProfileSelection(armAutomation: true)
            return
        }
        recording.awaitingProfileContext = true
        profileSelectionTask = Task { [weak self, weak recording] in
            await recording?.calendarLookupTask?.value
            guard !Task.isCancelled, let self, let recording,
                  self.appState.currentRecording?.id == recording.id else { return }
            recording.awaitingProfileContext = false
            self.profileSelectionTask = nil
            self.refreshPostRecordingProfileSelection(armAutomation: true)
        }
    }

    /// Re-evaluate context changes only while the finished capture is still in
    /// review. The worker owns live settings until all current job work stops.
    func refreshPostRecordingProfileSelection(armAutomation: Bool = false) {
        guard appState.showPostRecordingSheet, !postRecordingAction.isBusy,
              let recording = appState.currentRecording, !recording.awaitingProfileContext,
              recording.profileSelection.baselineID != nil else { return }
        if recording.profileSelection.isManual {
            guard appState.processingJob == nil, !processingCancellationInProgress,
                  let profileID = recording.profileSelection.retainedManualChoice(savedManualID: appSettings.activeProfileId),
                  appSettings.profiles.contains(where: { $0.id == profileID }) else { return }
            appSettings.routeAutomatically(to: profileID, for: recording.id)
            return
        }
        let oldID = appSettings.activeProfile.id
        let wasDeferred = recording.profileSelection.isDeferred
        let selected = recording.profileSelection.evaluate(profiles: appSettings.profiles,
            context: ProfileMatchContext(recording: recording), activeID: oldID,
            workerBusy: appState.processingJob != nil || processingCancellationInProgress,
            manualID: appSettings.activeProfileId)
        guard !recording.profileSelection.isManual else { return }
        if let selected, selected != oldID {
            cancelPostRecordingAutomation(manualOverride: false)
        }
        if let selected {
            appSettings.routeAutomatically(to: selected, for: recording.id)
        }
        if !recording.profileSelection.isDeferred && (armAutomation || wasDeferred || selected.map { $0 != oldID } == true) {
            schedulePostRecordingAutomation()
        }
    }

    func selectPostRecordingProfile(_ id: UUID) {
        guard appState.processingJob == nil, !processingCancellationInProgress,
              !postRecordingAction.isBusy, appSettings.profiles.contains(where: { $0.id == id }) else { return }
        cancelPostRecordingAutomation()
        appState.currentRecording?.profileSelection.chooseManually(id, savedManualID: id)
        appSettings.setActiveProfile(id)
    }

    private func automaticPostRecordingRequest(for recording: Recording) -> AutomaticPostRecordingRequest {
        .init(recordingID: recording.id, profile: appSettings.activeProfile,
              transcribe: appSettings.effectiveAutoTranscribe,
              summary: appSettings.effectiveAutoSummary,
              actionItems: appSettings.effectiveAutoActionItems,
              tags: appSettings.effectiveAutoTags,
              configuration: AutomaticPostRecordingConfiguration(settings: appSettings))
    }

    /// Only a newly finished capture arms automatic work. Recovered recordings
    /// and explicit imports keep their existing review flow.
    private func schedulePostRecordingAutomation() {
        cancelPostRecordingAutomation(manualOverride: false)
        guard let recording = appState.currentRecording else { return }
        postRecordingAutomation.schedule(automaticPostRecordingRequest(for: recording))
        guard postRecordingAutomation.isPending else { return }
        postRecordingAutomationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, let pending = self.postRecordingAutomation.request else { return }
                guard self.appState.recordingState == .idle,
                      self.appState.showPostRecordingSheet,
                      !self.postRecordingAction.isBusy,
                      let recording = self.appState.currentRecording,
                      self.automaticPostRecordingRequest(for: recording) == pending else {
                    self.cancelPostRecordingAutomation()
                    return
                }
                guard let request = self.postRecordingAutomation.claim() else { continue }
                self.postRecordingAutomationTask = nil
                // Match the manual preflight. An incomplete remote configuration
                // returns to review instead of starting a predictably failing job.
                if request.profile.postRecordingPolicy == .process && request.transcribe
                    && self.appSettings.effectiveTranscriptionEngine == .remoteEndpoint
                    && self.appSettings.effectiveDefaultTranscriptionEndpoint == nil {
                    self.appState.lastError = "Choose a transcription endpoint before processing this recording."
                    return
                }
                switch request.profile.postRecordingPolicy {
                case .review: break
                case .process:
                    self.startProcessing(transcribe: request.transcribe, summary: request.summary,
                                         actionItems: request.actionItems, tags: request.tags)
                case .queue:
                    Task { await self.queueForLater(transcribe: request.transcribe, summary: request.summary,
                                                   actionItems: request.actionItems, tags: request.tags) }
                }
                return
            }
        }
    }

    /// Looks up calendar events matching the finished recording's true span and publishes the
    /// ranked candidates + best match. The post-recording sheet observes both to drive the
    /// override picker and pre-fill the title/participants. Never clobbers a `calendarEvent`
    /// the user already picked.
    private func lookupCalendarCandidates(for recording: Recording) async {
        let start = recording.date
        let end = start.addingTimeInterval(recording.duration)
        let includeFullRecordingDay = appSettings.showAllMeetingsFromRecordingDay
        let fallbackWindow = TimeInterval(appSettings.calendarMatchWindowMinutes * 60)
        let events: [CalendarEvent]
        switch appSettings.effectiveCalendarSource {
        case .iCal:
            events = await calendarService.findEvents(
                recordingStart: start,
                recordingEnd: end,
                includeFullRecordingDay: includeFullRecordingDay,
                selectedCalendarIDs: appSettings.selectedICalCalendarIDs
            )
        case .outlook:
            events = await outlookCalendarService.findEvents(
                recordingStart: start,
                recordingEnd: end,
                includeFullRecordingDay: includeFullRecordingDay
            )
        case .disabled:
            events = []
        }

        let automaticMatches = CalendarMatcher.rankedMatches(
            from: events,
            recordingStart: start,
            recordingEnd: end,
            fallbackWindow: fallbackWindow
        )
        recording.calendarCandidates = CalendarMatcher.displayCandidates(
            from: events,
            automaticMatches: automaticMatches,
            recordingStart: start,
            includeFullRecordingDay: includeFullRecordingDay
        )
        if recording.calendarEvent == nil {
            recording.calendarEvent = automaticMatches.first
        }
    }

    func pauseRecording() {
        captureCoordinator.pause()
    }

    func resumeRecording() throws {
        try captureCoordinator.resume()
    }

    /// Switch the microphone input device while recording (manual hot-swap). Persists
    /// the selection and re-points the live mic engine at the new device, keeping the
    /// in-progress mic track continuous.
    func switchInputDevice(to uid: String?) {
        guard !captureCoordinator.isStopping, !captureCoordinator.isTerminating else { return }
        appSettings.audioInputDeviceUID = uid ?? ""
        do {
            try captureCoordinator.switchInputDevice(to: uid)
        } catch {
            appState.lastError = "Couldn't switch microphone: \(error.localizedDescription)"
        }
    }

    /// Runs the full pipeline for one background `ProcessingJob`. The job is created and
    /// installed on `AppState.processingJob` by `launchJob(...)` before this runs, and torn
    /// down via `finishJob(_:)` at the pipeline's terminal points — NOT when this task
    /// returns (a confirm-first review makes it return early while the job stays alive).
    func processRecording(
        job: ProcessingJob,
        transcribe: Bool,
        summary: Bool,
        actionItems: Bool,
        tags: Bool,
        stopBeforeIntegrations: Bool = false
    ) async {
        guard !Task.isCancelled, appState.processingJob === job else { return }
        let recording = job.recording
        let localAIAvailable: Bool = {
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                return LocalAIService.isAvailable
            }
            return false
            #else
            return false
            #endif
        }()
        recordingReviewSlot.dismiss(for: recording)
        appState.preflightWarning = nil
        appState.processingSteps = []
        appState.liveInferenceText = nil
        // NOTE: the capture live-preview fields (liveTranscriptSegments, liveVolatile*,
        // isLiveTranscribing, liveStatusMessage) are deliberately NOT cleared here — a new
        // recording may be capturing concurrently and owns them. This job's progressive
        // segments go to `job.progressiveSegments` instead.

        // Initialize this job's UI before the diagnostic hop. A concurrent capture
        // may open a new post-recording sheet while the journal write is awaiting.
        await processingPipeline.recordProcessingDiagnostic(
            .started(transcribe: transcribe, summary: summary, actionItems: actionItems, tags: tags), recordingID: recording.id)
        guard !Task.isCancelled, appState.processingJob === job else { return }

        let progress = PreparationProgress()
        do {
            let prepared = try await processingPipeline.prepareWorkflow(transcribe: transcribe, steps: .init(
                waitForCalendar: { @MainActor in
                    try self.requireProcessingOwnership(job)
                    await recording.calendarLookupTask?.value
                    try self.requireProcessingOwnership(job)
                }, finalize: { @MainActor in
                    try await self.finalizePreparation(job: job, progress: progress)
                }, finalizationCommitted: { @MainActor in
                    try self.requireProcessingOwnership(job)
                    if let index = progress.finalizationIndex { self.markCompleted(index) }
                    let problems = recording.finalizationWarnings.filter { !FinalizationWarning.isInformational($0) }
                    if !problems.isEmpty {
                        self.appState.processingSteps.append(ProcessingStep(name: "Audio finalization warnings", status: .failed(problems.joined(separator: "\n"))))
                    }
                }, meetingContext: { @MainActor in
                    try self.requireProcessingOwnership(job)
                    await self.persistMeetingContext(for: recording, job: job)
                }, prewarm: { @MainActor in
                    try self.requireProcessingOwnership(job)
                    self.prewarmPreparationModel()
                }, loadTranscript: { @MainActor in
                    try self.requireProcessingOwnership(job)
                    let saved = await self.loadSavedTranscript(for: recording)
                    try self.requireProcessingOwnership(job)
                    return saved
                }, transcribe: { @MainActor in
                    try await self.transcribePreparation(job: job, progress: progress)
                }, publishTranscript: { @MainActor result, loaded in
                    try self.requireProcessingOwnership(job)
                    if loaded {
                        progress.transcriptionIndex = self.appState.processingSteps.count
                        self.appState.processingSteps.append(ProcessingStep(name: "Loaded saved transcript", status: .inProgress))
                    }
                    recording.transcription = result
                }, saveTranscript: { @MainActor result in
                    try await self.saveTranscript(result, for: job)
                }, checkpoint: { @MainActor stage in
                    try self.requireProcessingOwnership(job)
                    try await self.persistCheckpoint(stage, for: job)
                    try self.requireProcessingOwnership(job)
                }, retireQueue: { @MainActor in
                    try self.requireProcessingOwnership(job)
                    try await self.completeLegacyQueueCheckpoint(for: job)
                }, transcriptCommitted: { @MainActor result, fresh in
                    try self.requireProcessingOwnership(job)
                    if fresh { self.appSettings.lifetimeTranscribedSeconds += recording.duration }
                    if let index = progress.transcriptionIndex { self.markCompleted(index) }
                    if fresh, let warnings = result.warnings, !warnings.isEmpty {
                        self.appState.processingSteps.append(ProcessingStep(name: "Transcription warnings", status: .failed(warnings.joined(separator: "\n"))))
                    }
                }, speakers: { @MainActor result, perf in
                    try self.requireProcessingOwnership(job)
                    do {
                        return try await self.prepareDiarizationAndSpeakerReview(job: job, result: result,
                            transcribe: transcribe, summary: summary, actionItems: actionItems, tags: tags,
                            localAIAvailable: localAIAvailable, stopBeforeIntegrations: stopBeforeIntegrations, perf: perf)
                    } catch {
                        let stage: PersistedProcessingJob.FailureStage = job.persistedRecord?.checkpoint.hasCompleted(.diarized) == true ? .speakerReview : .diarization
                        throw ProcessingPipeline.PreparationFailure(stage: stage, phase: .speakers, underlying: error)
                    }
                }, validateOwnership: { @MainActor in try self.requireProcessingOwnership(job) }))
            try requireProcessingOwnership(job)
            if prepared.heldForReview || appState.pendingSpeakerReview?.recording === recording { return }
            await runAnalysisAndExport(recording: recording, transcribe: transcribe, summary: summary,
                actionItems: actionItems, tags: tags, localAIAvailable: localAIAvailable,
                perf: prepared.perf, stopBeforeIntegrations: stopBeforeIntegrations)
        } catch {
            guard !Task.isCancelled, appState.processingJob === job else { return }
            let failure = error as? ProcessingPipeline.PreparationFailure
                ?? .init(stage: .persistence, phase: .finalization, underlying: error)
            switch failure.phase {
            case .finalization:
                markFailed(progress.finalizationIndex, failure.underlying.localizedDescription)
            case .transcription:
                markFailed(progress.transcriptionIndex, failure.underlying.localizedDescription)
                if progress.transcriptionIndex != nil {
                    Logger.transcription.error("Transcription failed; details shown in the processing UI")
                    await processingPipeline.recordProcessingDiagnostic(.transcriptionFailed(.init(error: failure.underlying)),
                                                                         recordingID: recording.id)
                }
            case .speakers:
                if transcribe {
                    appState.processingSteps.append(ProcessingStep(name: "Preparing speakers", status: .failed(failure.underlying.localizedDescription)))
                }
            }
            guard !Task.isCancelled, appState.processingJob === job else { return }
            await markPersistedJobFailed(failure.stage, job: job)
            if failure.phase != .speakers { await ensureRetryQueue(for: job) }
            guard !Task.isCancelled, appState.processingJob === job else { return }
            if failure.phase == .finalization, appState.currentRecording === recording, appState.recordingState == .idle {
                appState.showPostRecordingSheet = true
            }
            await finishJob(job, completed: false)
        }
    }

    @MainActor private final class PreparationProgress {
        var finalizationIndex: Int?
        var transcriptionIndex: Int?
    }

    private func finalizePreparation(job: ProcessingJob, progress: PreparationProgress) async throws {
        try requireProcessingOwnership(job)
        let index = appState.processingSteps.count
        progress.finalizationIndex = index
        appState.processingSteps.append(ProcessingStep(name: "Finalizing audio", status: .inProgress))
        let callback = ProcessingStepProgress(appState: appState, job: job, stepIndex: index)
        defer { callback.invalidate() }
        try await ensureRecordingFinalized(recording: job.recording) { fraction in
            Task { @MainActor in callback.update { step, _ in step.progress = fraction } }
        }
        try requireProcessingOwnership(job)
    }

    private func prewarmPreparationModel() {
        guard appSettings.effectiveAIProcessingEnabled, appSettings.effectiveAIEngine == .appleIntelligence else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { Task { await LocalAIService().prewarm() } }
        #endif
    }

    private func transcribePreparation(job: ProcessingJob, progress: PreparationProgress) async throws -> ProcessingPipeline.WorkflowTranscription {
        try requireProcessingOwnership(job)
        let recording = job.recording
        let settings = ProcessingPipeline.TranscriptionSettings(settings: appSettings)
        let index = appState.processingSteps.count
        progress.transcriptionIndex = index
        let name: String = switch settings.engine {
        case .appleSpeech: "Transcribing (Apple Speech)"
        case .localWhisper: "Transcribing (Local Whisper)"
        case .parakeetLocal: "Transcribing (Parakeet)"
        case .remoteEndpoint: "Transcribing audio"
        }
        appState.processingSteps.append(ProcessingStep(name: name, status: .inProgress))
        let output = try await transcribeRecordingAudio(recording: recording, stepIndex: index, settings: settings)
        try requireProcessingOwnership(job)
        return .init(transcription: output.transcription, model: settings.modelDisplayName,
                     audioDuration: recording.duration, spellCorrectionTime: output.spellCorrectionTime)
    }

    private func prepareDiarizationAndSpeakerReview(
        job: ProcessingJob,
        result: TranscriptionResult,
        transcribe: Bool,
        summary: Bool,
        actionItems: Bool,
        tags: Bool,
        localAIAvailable: Bool,
        stopBeforeIntegrations: Bool,
        perf: TranscriptionPerf
    ) async throws -> Bool {
        try requireProcessingOwnership(job)
        let recording = job.recording
        let input = ProcessingPipeline.SpeakerRequest(transcription: result,
            participants: recording.participants,
            roster: recording.participants + (recording.calendarEvent?.attendeeNames ?? []),
            mode: appSettings.speakerIdMode,
            reviewAlreadyCompleted: job.persistedRecord?.checkpoint.hasCompleted(.speakerReviewCompleted) == true,
            reviewRequired: job.persistedRecord?.speakerReviewRequired)
        let sidecarURL = recording.transcriptSidecarURL
        let libraryStore = voiceLibraryStore
        let richStore = transcriptStore
        return try await processingPipeline.prepareSpeakers(input, steps: .init(
            loadLibrary: { await libraryStore.load() },
            loadTranscript: { required in
                guard let sidecarURL else { throw TranscriptStoreError.noSidecarURL }
                let exists = await richStore.exists(at: sidecarURL)
                try Task.checkCancellation()
                if exists || required { return try await richStore.load(from: sidecarURL) }
                return nil
            }, saveTranscript: { rich in
                guard let sidecarURL else { throw TranscriptStoreError.noSidecarURL }
                try await richStore.save(rich, to: sidecarURL)
            }, publishTranscript: { @MainActor rich in
                try self.requireProcessingOwnership(job)
                recording.richTranscript = rich
            }, checkpointDiarized: { @MainActor held in
                try self.requireProcessingOwnership(job)
                if var record = job.persistedRecord {
                    self.updatePersistedSource(&record.source, from: recording)
                    record.speakerReviewRequired = held
                    _ = record.markCompleted(.diarized, at: Date())
                    if held { record.markWaitingForSpeakerReview(at: Date()) }
                    try await self.processingJobStore.save(record)
                    try self.requireProcessingOwnership(job)
                    job.persistedRecord = record
                }
            }, holdReview: { @MainActor items in
                try self.requireProcessingOwnership(job)
                self.appState.pendingSpeakerReview = SpeakerReviewSession(recording: recording,
                    masterAudioURL: recording.finalizedAudioURL, items: items,
                    transcribe: transcribe, summary: summary, actionItems: actionItems, tags: tags,
                    localAIAvailable: localAIAvailable, perf: perf,
                    stopBeforeIntegrations: stopBeforeIntegrations)
                self.appState.recordingStatusNote = "Waiting for speaker confirmation"
                SpeakerReviewWindowController.shared.show()
                self.sendReviewReadyNotification()
                Logger.transcription.info("Confirm-first: holding \(items.count) speaker(s) for review")
            }, enroll: { @MainActor entry in
                try self.requireProcessingOwnership(job)
                let id = await libraryStore.upsert(name: entry.name,
                    voiceprint: Voiceprint(embedding: entry.embedding, model: "fluidaudio-wespeaker-256", capturedAt: Date()))
                try self.requireProcessingOwnership(job)
                await self.suggestCompany(forPersonId: id, name: entry.name, recording: recording)
                try self.requireProcessingOwnership(job)
            }, completeReview: { @MainActor in
                try await self.persistCheckpoint(.speakerReviewCompleted, for: job)
            }, validateOwnership: { @MainActor in try self.requireProcessingOwnership(job) }))
    }

    /// Normal processing and speaker-review resume share the actor's restartable workflow.
    private func runAnalysisAndExport(
        recording: Recording, transcribe: Bool, summary: Bool, actionItems: Bool,
        tags: Bool, localAIAvailable: Bool, perf: TranscriptionPerf,
        stopBeforeIntegrations: Bool = false
    ) async {
        guard !Task.isCancelled, let job = appState.processingJob, job.recording === recording else { return }
        await runExportWorkflow(job: job, mode: .processing, transcribe: transcribe,
            summary: summary, actionItems: actionItems, tags: tags,
            localAIAvailable: localAIAvailable, perf: perf, stopBeforeIntegrations: stopBeforeIntegrations)
    }

    @MainActor private final class ExportProgress {
        var aiModel: String?
        var aiTime: TimeInterval?
        var titleTime: TimeInterval?
        var markdownIndex: Int?
        var markdownTitle: String?
    }

    /// Snapshots workflow options and bridges actor operations to job-owned UI state.
    /// Stage sequencing and normal/recovery/retry failure policy live in ProcessingPipeline.
    private func runExportWorkflow(
        job: ProcessingJob, mode: ProcessingPipeline.ExportWorkflowMode,
        transcribe: Bool, summary: Bool, actionItems: Bool, tags: Bool,
        localAIAvailable: Bool, perf: TranscriptionPerf, stopBeforeIntegrations: Bool = false
    ) async {
        guard !Task.isCancelled, appState.processingJob === job else { return }
        let recording = job.recording
        let progress = ExportProgress()
        let input = ProcessingPipeline.ExportWorkflowRequest(mode: mode,
            analysisAlreadyCompleted: job.persistedRecord?.checkpoint.hasCompleted(.analyzed) == true,
            runAnalysis: appSettings.effectiveAIProcessingEnabled && recording.transcription != nil,
            analysisRequested: appSettings.effectiveAIProcessingEnabled && (summary || actionItems || tags),
            writeMarkdown: transcribe || summary || actionItems || tags,
            stopBeforeIntegrations: stopBeforeIntegrations)
        do {
            let result = try await processingPipeline.analysisExportWorkflow(input, steps: .init(
                restoreAnalysis: { @MainActor in
                    try self.requireProcessingOwnership(job)
                    let expected = job.persistedRecord?.analysisOutputSaved ?? (summary || actionItems || tags)
                    let restored = try await self.processingPipeline.restoreAnalysis(from: recording.insightsSidecarURL,
                        required: expected, adoptLegacyMarkdown: job.persistedRecord?.markdownExport == nil,
                        insightsStore: self.insightsStore, markdownStore: self.markdownOutputStore)
                    try self.requireProcessingOwnership(job)
                    if let plan = restored.adoptedPlan { try await self.saveMarkdownPlan(plan, for: job) }
                    try self.requireProcessingOwnership(job)
                    if let insights = restored.insights { self.applyInsights(insights, to: recording) }
                }, analyze: { @MainActor in
                    try self.requireProcessingOwnership(job)
                    let output = try await self.runPipelineAnalysis(job: job, summary: summary,
                        actionItems: actionItems, tags: tags, localAIAvailable: localAIAvailable)
                    try self.requireProcessingOwnership(job)
                    progress.aiTime = output.duration
                    if output.duration != nil { progress.aiModel = output.modelDisplayName }
                }, saveAnalysis: { @MainActor in
                    try self.requireProcessingOwnership(job)
                    guard (!summary || recording.summary != nil),
                          (!actionItems || recording.actionItems != nil), (!tags || recording.tags != nil) else {
                        throw NSError(domain: "RecordingManager", code: 6, userInfo: [
                            NSLocalizedDescriptionKey: "One or more requested analysis outputs failed."
                        ])
                    }
                    try await self.persistInsightsSidecar(for: recording, markdownURL: nil)
                }, checkpointAnalysis: { @MainActor saved in
                    try self.requireProcessingOwnership(job)
                    job.persistedRecord?.analysisOutputSaved = saved
                    try await self.persistCheckpoint(.analyzed, for: job)
                }, title: { @MainActor in
                    try await self.exportWorkflowTitle(job: job, mode: mode, progress: progress)
                }, performance: { @MainActor in
                    try self.requireProcessingOwnership(job)
                    self.logModelPerformance(label: self.performanceLabel(for: recording),
                        transcriptionModel: perf.model, audioDuration: perf.audioDuration,
                        transcriptionTime: perf.time, inferenceTime: perf.inference,
                        diarizationTime: perf.diarization, finalizationTime: perf.finalization,
                        aiModel: progress.aiModel, aiTime: progress.aiTime,
                        spellCorrectionTime: perf.spellCorrection, titleGenerationTime: progress.titleTime)
                }, markdown: { @MainActor selectedMode in
                    try self.requireProcessingOwnership(job)
                    progress.markdownIndex = self.appState.processingSteps.count
                    self.appState.processingSteps.append(ProcessingStep(name: "Writing Markdown", status: .inProgress))
                    let markdownMode: ProcessingPipeline.MarkdownMode = selectedMode == .retry ? .regenerate
                        : .restartable(jobID: job.id, savedPlan: job.persistedRecord?.markdownExport,
                            alreadyCompleted: job.persistedRecord?.checkpoint.hasCompleted(.markdownGenerated) == true)
                    let output = try await self.publishPipelineMarkdown(for: job, mode: markdownMode)
                    try self.requireProcessingOwnership(job)
                    progress.markdownTitle = output.plan.generatedTitle
                    if selectedMode == .processing { recording.generatedTitle = output.plan.generatedTitle }
                    return output.url
                }, persistTitle: { @MainActor in
                    try self.requireProcessingOwnership(job)
                    await self.persistGeneratedTitle(for: recording, job: job)
                    try self.requireProcessingOwnership(job)
                }, updateExportLink: { @MainActor url in
                    try self.requireProcessingOwnership(job)
                    try await self.processingPipeline.updateAnalysisExportLink(at: recording.insightsSidecarURL,
                        markdownURL: url, generatedTitle: progress.markdownTitle, store: self.insightsStore)
                    try self.requireProcessingOwnership(job)
                }, saveRetryInsights: { @MainActor url in
                    try self.requireProcessingOwnership(job)
                    try await self.persistInsightsSidecar(for: recording, markdownURL: url)
                }, prepareDeliveries: { @MainActor url in
                    _ = try await self.prepareIntegrationDeliveries(job: job, markdownURL: url)
                }, checkpointMarkdown: { @MainActor in
                    try await self.persistCheckpoint(.markdownGenerated, for: job)
                }, markdownCommitted: { @MainActor in
                    try self.requireProcessingOwnership(job)
                    if let index = progress.markdownIndex { self.markCompleted(index) }
                }, dispatch: { @MainActor url, held in
                    try self.requireProcessingOwnership(job)
                    return await self.dispatchTrackedIntegrations(job: job, markdownURL: url, stopBeforeIntegrations: held)
                }, reportFailure: { @MainActor failure in
                    try await self.reportExportWorkflowFailure(failure, job: job, progress: progress)
                }, validateOwnership: { @MainActor in try self.requireProcessingOwnership(job) }))
            try requireProcessingOwnership(job)
            if result == .completed { await notifyExportWorkflowCompletion(job: job) }
            await finishJob(job, completed: result == .completed)
        } catch {
            // Owning-task cancellation and replacement are handled by Stop. An
            // unexpected adapter failure still retires the active job explicitly.
            guard !Task.isCancelled, appState.processingJob === job else { return }
            await markPersistedJobFailed(.analysis, job: job)
            await ensureRetryQueue(for: job)
            guard !Task.isCancelled, appState.processingJob === job else { return }
            await finishJob(job, completed: false)
        }
    }

    private func exportWorkflowTitle(job: ProcessingJob, mode: ProcessingPipeline.ExportWorkflowMode,
                                     progress: ExportProgress) async throws {
        try requireProcessingOwnership(job)
        let recording = job.recording
        let engine = appSettings.effectiveAIEngine
        guard mode == .retry || job.persistedRecord?.markdownExport == nil,
              engine != .qwenLocal, engine != .localCLI, engine != .appleIntelligence,
              let transcription = recording.transcription else { return }
        let endpoint = appSettings.effectiveDefaultAIEndpoint
        let text = try await processingPipeline.prepareTitleTranscript(transcription)
        try requireProcessingOwnership(job)
        guard !text.isEmpty else { return }
        let index = appState.processingSteps.count
        appState.processingSteps.append(ProcessingStep(name: "Generating Title", status: .inProgress))
        defer {
            if !Task.isCancelled, appState.processingJob === job { markCompleted(index) }
        }
        if shouldGenerateTitle(for: recording), engine == .remoteEndpoint,
           let endpoint {
            progress.titleTime = try await generatePipelineTitle(for: job, transcription: text, endpoint: endpoint)
        }
        try requireProcessingOwnership(job)
    }

    private func reportExportWorkflowFailure(_ failure: ProcessingPipeline.ExportWorkflowFailure,
                                            job: ProcessingJob, progress: ExportProgress) async throws {
        try requireProcessingOwnership(job)
        let stage: PersistedProcessingJob.FailureStage
        switch failure.phase {
        case .loadingAnalysis, .savingAnalysis:
            let name = failure.phase == .loadingAnalysis ? "Loading saved analysis"
                : failure.phase == .savingAnalysis ? "Saving analysis" : "Analyzing recording"
            appState.processingSteps.append(ProcessingStep(name: name, status: .failed(failure.underlying.localizedDescription)))
            stage = .analysis
        case .analyzing:
            // The analysis adapter has already marked the affected field steps.
            stage = .analysis
        case .writingMarkdown:
            markFailed(progress.markdownIndex, failure.underlying.localizedDescription)
            stage = .markdown
        case .checkpointingMarkdown:
            stage = .persistence
        }
        if failure.disposition != .continueWorkflow {
            await markPersistedJobFailed(stage, job: job)
            try requireProcessingOwnership(job)
        }
        if failure.disposition == .stopAndQueue {
            await ensureRetryQueue(for: job)
            try requireProcessingOwnership(job)
        }
    }

    private func notifyExportWorkflowCompletion(job: ProcessingJob) async {
        guard !Task.isCancelled, appState.processingJob === job else { return }
        let failed = appState.processingSteps.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
        sendCompletionNotification(fileName: job.recording.fileName, failed: failed)
        await processingPipeline.recordProcessingDiagnostic(
            .completed(stepCount: appState.processingSteps.count, failedStepCount: failed), recordingID: job.recording.id)
    }

    /// Releases only the exact job whose pipeline reached this terminal point.
    /// Actor persistence precedes UI release; stale callbacks never drain/reset queues.
    private func finishJob(_ job: ProcessingJob, completed: Bool = true) async {
        guard !Task.isCancelled, appState.processingJob === job else { return }
        let succeeded = !appState.processingSteps.contains {
            if case .failed = $0.status { return true }
            return false
        }
        let input = ProcessingPipeline.TeardownRequest(completed: completed, processingSucceeded: succeeded,
            record: job.persistedRecord, completion: job.successfulCompletion, queuedAudioURL: job.queuedAudioURL)
        let store = processingJobStore
        do {
            try await processingPipeline.teardown(input, steps: .init(
                saveRecord: { try await store.save($0) },
                publishRecord: { @MainActor record in
                    try self.requireProcessingOwnership(job)
                    job.persistedRecord = record
                }, saveCompletion: { @MainActor completion in
                    try self.requireProcessingOwnership(job)
                    try await self.persistProcessingCompletion(completion, for: job)
                }, removeQueue: { audio in
                    try? await self.queueScheduleStore.retireItem(at: audio, expectedID: job.id)
                }, warning: { @MainActor warning in
                    try self.requireProcessingOwnership(job)
                    switch warning {
                    case .journal:
                        self.appState.lastError = "Processing finished, but its completion checkpoint couldn't be saved."
                    case .metadata:
                        self.appState.lastError = "Processing finished, but its library completion date couldn't be saved. The recovery journal is retained for retry."
                    }
                }, validateOwnership: { @MainActor in try self.requireProcessingOwnership(job) }))
            try requireProcessingOwnership(job)
        } catch { return }
        appState.processingJob = nil
        appSettings.finishAutomaticRouting(for: job.recording.id)
        if !completed {
            // Failed work must stay user-deferred instead of being selected again.
            drainAllQueued = false
        }
        await drainQueueIfNeeded()
        await drainReprocessingQueue()
        refreshPostRecordingProfileSelection()
    }

    private func updatePersistedSource(
        _ source: inout PersistedProcessingJob.Source,
        from recording: Recording
    ) {
        source.duration = recording.duration
        source.fileSize = recording.fileSize
        source.meetingTitle = recording.meetingTitleDraft
        source.associatedApp = recording.associatedApp
        source.participants = recording.participants
        source.calendarEvent = recording.calendarEvent
        source.echoSuppressionApplied = recording.echoSuppressionApplied
        source.recoveryManifestPath = recording.recoveryManifestURL?.path
        source.stagedInputPath = recording.importSourceURL?.path
        source.finalizedAudioPath = recording.finalizedAudioURL?.path
        source.segmentAudioPaths = recording.segmentAudioURLs.map(\.path)
        source.metadataPath = recording.metadataURL?.path
    }

    private func persistCheckpoint(
        _ stage: ProcessingCheckpointStage,
        for job: ProcessingJob
    ) async throws {
        try requireProcessingOwnership(job)
        guard var record = job.persistedRecord else { return }
        updatePersistedSource(&record.source, from: job.recording)
        if stage == .speakerReviewCompleted,
           record.status == .waitingForSpeakerReview {
            record.markRunning(at: Date())
        }
        if stage == .speakerReviewCompleted {
            record.speakerReviewRequired = false
        }
        _ = record.markCompleted(stage, at: Date())
        try await processingJobStore.save(record)
        try requireProcessingOwnership(job)
        job.persistedRecord = record
    }

    private func markPersistedJobFailed(
        _ stage: PersistedProcessingJob.FailureStage,
        job: ProcessingJob
    ) async {
        guard !Task.isCancelled, appState.processingJob === job else { return }
        guard var record = job.persistedRecord else { return }
        updatePersistedSource(&record.source, from: job.recording)
        record.markFailed(stage, at: Date())
        do {
            try await processingJobStore.save(record)
            guard !Task.isCancelled, appState.processingJob === job else { return }
            job.persistedRecord = record
        } catch {
            Logger.recording.error("Failed to persist processing-job failure state")
        }
    }

    func requireProcessingOwnership(_ job: ProcessingJob) throws {
        try Task.checkCancellation()
        guard appState.processingJob === job else { throw CancellationError() }
    }

    private func saveMarkdownPlan(_ plan: MarkdownExportPlan, for job: ProcessingJob) async throws {
        try requireProcessingOwnership(job)
        guard var record = job.persistedRecord else { return }
        record.markdownExport = plan
        record.updatedAt = Date()
        try await processingJobStore.save(record)
        try requireProcessingOwnership(job)
        job.persistedRecord = record
    }

    private func markMarkdownBoundaryReached(_ job: ProcessingJob) async throws {
        try requireProcessingOwnership(job)
        guard var record = job.persistedRecord else { return }
        updatePersistedSource(&record.source, from: job.recording)
        record.markMarkdownBoundaryReached(at: Date())
        try await processingJobStore.save(record)
        try requireProcessingOwnership(job)
        job.persistedRecord = record
    }

    /// A legacy queue sidecar is retired once transcription is durably checkpointed;
    /// later recovery is driven by the processing-job manifest and stage sidecars.
    private func completeLegacyQueueCheckpoint(for job: ProcessingJob) async throws {
        try requireProcessingOwnership(job)
        guard let audioURL = job.queuedAudioURL else { return }
        queueRefreshGeneration += 1
        try await queueScheduleStore.retireItem(at: audioURL, expectedID: job.id)
        try requireProcessingOwnership(job)
        guard job.queuedAudioURL == audioURL else { throw CancellationError() }
        job.queuedAudioURL = nil
        await refreshWorkQueue()
        try requireProcessingOwnership(job)
    }

    /// Keep existing History/manual-queue recovery available for failed or
    /// cancelled jobs while the durable store becomes the source of truth.
    private func ensureRetryQueue(for job: ProcessingJob) async {
        guard !Task.isCancelled, appState.processingJob === job else { return }
        guard job.recording.finalizedAudioURL != nil else { return }

        let request = job.persistedRecord?.request
        let item = QueueItem(
            id: job.id,
            transcribe: request?.transcribe ?? true,
            summary: request?.summary ?? appSettings.autoSummary,
            actionItems: request?.actionItems ?? appSettings.autoActionItems,
            tags: request?.tags ?? appSettings.autoTags,
            titleWasUserProvided: request?.titleWasUserProvided
                ?? job.recording.titleWasUserProvided,
            autoQueued: false,
            profileID: job.persistedRecord?.source.profileID
        )
        try? await saveQueueItem(item, for: job.recording)
        guard !Task.isCancelled, appState.processingJob === job else { return }
        await refreshWorkQueue()
    }

    func canLaunchProcessing(for recording: Recording, reprocessingAttemptID: UUID? = nil) -> Bool {
        reprocessingRecoveryReady && (reprocessingAttemptID != nil || !isReprocessing(recording.finalizedAudioURL ?? recording.fileURL))
            && !reprocessingAdmissionBusy && !queueMutationInProgress && !queuePauseWriteInProgress && !queueEnqueueInProgress
            && !recoveryMaintenanceInProgress && !processingCancellationInProgress && appState.processingJob == nil
            && appState.pendingSpeakerReview?.recording !== recording
            && speakerReviewOperation?.recording !== recording
            && captureCoordinator.recordingID != recording.id && !captureCoordinator.isTerminating
    }

    /// Creates a `ProcessingJob` for `recording`, installs it as the single active job, and
    /// runs `body` inside the job's own cancellable task. `processingRecording` is kept so
    /// the results/completion UI targets this recording, not a newer capture slot.
    @discardableResult
    func launchJob(
        id: UUID = UUID(),
        recording: Recording,
        queuedAudioURL: URL? = nil,
        persistedRequest: PersistedProcessingJob.Request? = nil,
        existingRecord: PersistedProcessingJob? = nil,
        reprocessingAttemptID: UUID? = nil,
        onPreparationFailure: ((String) -> Void)? = nil,
        _ body: @escaping (ProcessingJob) async -> Void
    ) -> ProcessingJob {
        let job = ProcessingJob(
            id: existingRecord?.id ?? id,
            recording: recording,
            queuedAudioURL: queuedAudioURL
        )
        job.reprocessingAttemptID = reprocessingAttemptID
        job.observesProcessingFromStart = existingRecord?.checkpoint.lastCompletedStage == nil
        guard canLaunchProcessing(for: recording, reprocessingAttemptID: reprocessingAttemptID) else {
            let message = "Finish the active processing, speaker review, or cleanup operation first."
            appState.lastError = message
            onPreparationFailure?(message)
            return job
        }
        if reprocessingAttemptID == nil, let profileID = existingRecord?.source.profileID {
            guard appSettings.profiles.contains(where: { $0.id == profileID }) else {
                let message = "This recording’s saved profile was deleted. Choose a profile and retry from the recording."
                appState.lastError = message
                onPreparationFailure?(message)
                return job
            }
            appSettings.routeAutomatically(to: profileID, for: recording.id)
        }
        if reprocessingAttemptID == nil, let owner = appSettings.automaticProfileRecordingID, owner != recording.id {
            appSettings.finishAutomaticRouting(for: owner)
        }
        appState.processingJob = job
        appState.processingRecording = recording
        job.task = Task {
            do {
                if var existingRecord {
                    if existingRecord.status != .waitingForSpeakerReview {
                        existingRecord.markRunning(at: Date())
                    }
                    try await self.processingJobStore.save(existingRecord)
                    job.persistedRecord = existingRecord
                } else if let persistedRequest {
                    if var stored = try await self.processingJobStore.load(id: job.id) {
                        job.observesProcessingFromStart = stored.checkpoint.lastCompletedStage == nil
                        // A fresh retry uses the selected profile; recovery uses
                        // existingRecord above to restore its saved identity.
                        stored.source.profileID = self.appSettings.activeProfile.id
                        stored.markRunning(at: Date())
                        try await self.processingJobStore.save(stored)
                        job.persistedRecord = stored
                    } else {
                        let record = self.makePersistedJob(
                            id: job.id,
                            recording: recording,
                            request: persistedRequest
                        )
                        job.persistedRecord = try await self.processingJobStore.create(
                            record,
                            stagingInputURL: recording.importSourceURL
                        )
                    }
                    if let stagedPath = job.persistedRecord?.source.stagedInputPath {
                        recording.importSourceURL = URL(fileURLWithPath: stagedPath)
                    }
                }
            } catch {
                let message = "Couldn't save processing progress. The recording was not processed."
                self.appState.lastError = message
                onPreparationFailure?(message)
                if self.appState.processingJob === job {
                    self.appState.processingJob = nil
                    self.appSettings.finishAutomaticRouting(for: recording.id)
                    self.refreshPostRecordingProfileSelection()
                }
                return
            }
            guard !Task.isCancelled else {
                onPreparationFailure?("Processing was cancelled before it started. You can try again.")
                return
            }
            let context = await recording.privacyContext()
            guard !Task.isCancelled, self.appState.processingJob === job else { return }
            job.privacyContext = context
            await PrivacyTrace.$context.withValue(context) { await body(job) }
        }
        return job
    }

    private func makePersistedJob(
        id: UUID,
        recording: Recording,
        request: PersistedProcessingJob.Request,
        status: PersistedProcessingJob.Status = .running
    ) -> PersistedProcessingJob {
        let now = Date()
        return PersistedProcessingJob(
            id: id,
            recordingID: recording.id,
            createdAt: now,
            updatedAt: now,
            status: status,
            request: request,
            source: PersistedProcessingJob.Source(
                recordingDate: recording.date,
                duration: recording.duration,
                fileSize: recording.fileSize,
                meetingTitle: recording.meetingTitleDraft,
                associatedApp: recording.associatedApp,
                participants: recording.participants,
                calendarEvent: recording.calendarEvent,
                echoSuppressionApplied: recording.echoSuppressionApplied,
                recoveryManifestPath: recording.recoveryManifestURL?.path,
                stagedInputPath: recording.importSourceURL?.path,
                finalizedAudioPath: recording.finalizedAudioURL?.path,
                segmentAudioPaths: recording.segmentAudioURLs.map(\.path),
                metadataPath: recording.metadataURL?.path,
                profileID: appSettings.activeProfile.id
            )
        )
    }

    private func processingRequest(
        transcribe: Bool,
        summary: Bool,
        actionItems: Bool,
        tags: Bool,
        titleWasUserProvided: Bool,
        autoResume: Bool
    ) -> PersistedProcessingJob.Request {
        PersistedProcessingJob.Request(
            transcribe: transcribe,
            summary: summary,
            actionItems: actionItems,
            tags: tags,
            titleWasUserProvided: titleWasUserProvided,
            autoResume: autoResume
        )
    }

    /// Starts the next eligible queued item as a background job, if no job is running.
    /// Auto-queued overflow items always drain; user-deferred items only when
    /// `drainAllQueued` is set (the manual "Process Queue" button). Chains: each finished
    /// job's `finishJob` calls this again until nothing eligible remains.
    func drainQueueIfNeeded(preferredAudioURL: URL? = nil, expectedID: UUID? = nil,
                            completingCancellation: Bool = false) async {
        guard completingCancellation || !Task.isCancelled else { return }
        if queueDrainInProgress { queueDrainRequested = true; return }
        guard reprocessingRecoveryReady, !reprocessingAdmissionBusy, appState.processingJob == nil, !queueMutationInProgress, !queueSafetyHold,
              !queueEnqueueInProgress, !queuePauseWriteInProgress, !recoveryMaintenanceInProgress,
              !processingCancellationInProgress, !reviewingIntegrationDeliveries else { return }
        queueDrainInProgress = true
        queueMutationInProgress = true
        await drainReservedQueue(preferredAudioURL: preferredAudioURL, expectedID: expectedID,
                                 completingCancellation: completingCancellation)
        queueMutationInProgress = false
        queueDrainInProgress = false
        if queueDrainRequested {
            queueDrainRequested = false
            await drainQueueIfNeeded(completingCancellation: completingCancellation)
        }
    }

    private func drainReservedQueue(preferredAudioURL: URL?, expectedID: UUID?, completingCancellation: Bool) async {
        let pauseGeneration = queuePauseGeneration
        let snapshot: QueueScheduleStore.Snapshot
        do {
            snapshot = try await queueScheduleStore.snapshot(configuredFolders: configuredQueueFolders)
        } catch {
            queueLoadError = "Saved queue settings could not be read. No queued work was started."
            return
        }
        guard completingCancellation || !Task.isCancelled,
              appState.processingJob == nil, !queueSafetyHold, !queueEnqueueInProgress, !queuePauseWriteInProgress, pauseGeneration == queuePauseGeneration,
              !recoveryMaintenanceInProgress, !processingCancellationInProgress,
              !reviewingIntegrationDeliveries else { return }
        queuePaused = snapshot.schedule.paused
        guard !queuePaused || preferredAudioURL != nil else { return }
        appState.queuedCount = snapshot.items.count
        guard let entry = snapshot.items.first(where: {
            guard $0.fileSize != nil, !isReprocessing($0.audioURL) else { return false }
            if let preferredAudioURL {
                return $0.audioURL.standardizedFileURL == preferredAudioURL.standardizedFileURL
                    && (expectedID == nil || $0.item.id == expectedID)
            }
            return drainAllQueued || $0.item.autoQueued
        }) else {
            drainAllQueued = false
            return
        }
        let audioURL = entry.audioURL
        let item = entry.item
        let size = entry.fileSize ?? 0
        let name = audioURL.deletingPathExtension().lastPathComponent
        let recording = Recording(
            id: item.id,
            fileURL: audioURL,
            fileSize: size,
            meetingTitleDraft: name,
            finalizedAudioURL: audioURL
        )
        recording.titleWasUserProvided = item.titleWasUserProvided
        if let profileID = item.profileID {
            guard appSettings.profiles.contains(where: { $0.id == profileID }) else {
                queueLoadError = "This queued recording’s profile was deleted. Choose a profile and retry from the recording."
                drainAllQueued = false
                return
            }
            appSettings.routeAutomatically(to: profileID, for: recording.id)
        }
        let request = processingRequest(
            transcribe: item.transcribe,
            summary: item.summary,
            actionItems: item.actionItems,
            tags: item.tags,
            titleWasUserProvided: item.titleWasUserProvided,
            autoResume: item.autoQueued
        )
        queueMutationInProgress = false // No suspension between admission release and launch.
        launchJob(
            id: item.id,
            recording: recording,
            queuedAudioURL: audioURL,
            persistedRequest: request
        ) { job in
            await self.processRecording(
                job: job,
                transcribe: item.transcribe,
                summary: item.summary,
                actionItems: item.actionItems,
                tags: item.tags
            )
        }
    }

    @MainActor final class ReviewOperation {
        let recording: Recording
        let job: ProcessingJob?
        let sidecarURL: URL?
        var transcript: RichTranscript?
        private var finished = false
        private var completionWaiters: [CheckedContinuation<Void, Never>] = []
        init(recording: Recording, job: ProcessingJob?) {
            self.recording = recording
            self.job = job
            sidecarURL = recording.transcriptSidecarURL
            transcript = recording.richTranscript
        }

        func finish() {
            guard !finished else { return }
            finished = true
            let waiters = completionWaiters
            completionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        func waitForCompletion() async {
            guard !finished else { return }
            await withCheckedContinuation { completionWaiters.append($0) }
        }

        /// Changed input still belongs to this operation's failure/teardown path;
        /// a replacement operation/job does not. Keep those decisions separate.
        func ownsLifecycle(current: ReviewOperation?, activeJob: ProcessingJob?, pendingReview: SpeakerReviewSession?) -> Bool {
            guard current === self, pendingReview == nil else { return false }
            if let job { return activeJob === job }
            return activeJob?.recording !== recording
        }

        func validateSnapshot() throws {
            guard recording.transcriptSidecarURL == sidecarURL, recording.richTranscript == transcript else {
                throw TranscriptStoreError.changedDuringReview
            }
        }
    }

    private func requireReviewOwnership(_ operation: ReviewOperation, recording: Recording) throws {
        try Task.checkCancellation()
        guard ownsReviewOperation(operation, recording: recording) else { throw CancellationError() }
        try operation.validateSnapshot()
    }

    private func ownsReviewOperation(_ operation: ReviewOperation, recording: Recording) -> Bool {
        !Task.isCancelled && operation.recording === recording
            && operation.ownsLifecycle(current: speakerReviewOperation, activeJob: appState.processingJob,
                                       pendingReview: appState.pendingSpeakerReview)
    }

    private func beginReviewOperation(_ session: SpeakerReviewSession) -> ReviewOperation? {
        guard !Task.isCancelled else { return nil }
        let job: ProcessingJob?
        if session.origin == .pipeline {
            guard let active = appState.processingJob, active.recording === session.recording else { return nil }
            job = active
        } else {
            guard appState.processingJob?.recording !== session.recording else { return nil }
            job = nil
        }
        let operation = ReviewOperation(recording: session.recording, job: job)
        speakerReviewOperation = operation
        appState.pendingSpeakerReview = nil
        appState.recordingStatusNote = nil
        return operation
    }

    /// Confirmed edits are saved before publication, enrollment and resume.
    func finishReview(sessionID: UUID, confirmed: [String: ConfirmedSpeaker]) async {
        if appState.pendingSpeakerReview?.origin == .reprocessing {
            await finishReprocessingReview(sessionID: sessionID, confirmed: confirmed)
            return
        }
        guard let session = appState.pendingSpeakerReview, session.id == sessionID,
              let operation = beginReviewOperation(session) else { return }
        defer {
            operation.finish()
            if speakerReviewOperation === operation { speakerReviewOperation = nil }
        }
        let recording = session.recording
        let store = transcriptStore
        let sidecarURL = operation.sidecarURL
        // These embeddings belong to the exact clustering the user reviewed.
        // Re-diarization must not enroll older raw-transcript cluster embeddings.
        let embeddings = Dictionary(session.items.map { ($0.id, $0.clusterEmbedding) }, uniquingKeysWith: { first, _ in first })
        do {
            try await processingPipeline.confirmSpeakers(confirmed, transcript: operation.transcript, steps: .init(
                loadTranscript: {
                    guard let url = sidecarURL else { throw TranscriptStoreError.noSidecarURL }
                    return try await store.load(from: url)
                }, save: { @MainActor rich, original in
                    try self.requireReviewOwnership(operation, recording: recording)
                    guard let url = operation.sidecarURL else { throw TranscriptStoreError.noSidecarURL }
                    try await store.save(rich, to: url, replacing: original)
                    try self.requireReviewOwnership(operation, recording: recording)
                }, publish: { @MainActor rich in
                    try self.requireReviewOwnership(operation, recording: recording)
                    recording.richTranscript = rich
                    operation.transcript = rich
                }, loadEmbeddings: { embeddings }, enroll: { @MainActor entry in
                    try self.requireReviewOwnership(operation, recording: recording)
                    let id = await self.voiceLibraryStore.upsert(name: entry.name,
                        voiceprint: .init(embedding: entry.embedding, model: "fluidaudio-wespeaker-256", capturedAt: Date()))
                    try self.requireReviewOwnership(operation, recording: recording)
                    await self.suggestCompany(forPersonId: id, name: entry.name, recording: recording)
                    try self.requireReviewOwnership(operation, recording: recording)
                }, validateOwnership: { @MainActor in try self.requireReviewOwnership(operation, recording: recording) }))
        } catch {
            guard ownsReviewOperation(operation, recording: recording) else { return }
            appState.lastError = "Speaker changes could not be saved. Processing remains retryable."
            if let job = operation.job {
                await markPersistedJobFailed(.speakerReview, job: job)
                guard ownsReviewOperation(operation, recording: recording) else { return }
                await finishJob(job, completed: false)
            }
            return
        }
        await resumeAfterReview(session: session, recording: recording, operation: operation)
    }

    /// Closing review keeps the resolver's saved names and resumes the owning job.
    func cancelReview(sessionID: UUID) async {
        if appState.pendingSpeakerReview?.origin == .reprocessing {
            if let job = appState.processingJob { await stopReprocessing(job) }
            return
        }
        guard let session = appState.pendingSpeakerReview, session.id == sessionID,
              let operation = beginReviewOperation(session) else { return }
        defer {
            operation.finish()
            if speakerReviewOperation === operation { speakerReviewOperation = nil }
        }
        await resumeAfterReview(session: session, recording: session.recording, operation: operation)
    }

    /// Shared tail of finish/cancel: the fresh-transcription hold resumes the AI →
    /// markdown → export pipeline; a transcript-viewer re-diarize only commits the
    /// names (already applied + persisted) and signals the open viewer to reload —
    /// re-analysis stays an explicit choice via the viewer's reanalysis banner.
    private func resumeAfterReview(session: SpeakerReviewSession, recording: Recording, operation: ReviewOperation) async {
        guard ownsReviewOperation(operation, recording: recording) else { return }
        do { try operation.validateSnapshot() }
        catch {
            appState.lastError = error.localizedDescription
            if let job = operation.job {
                await markPersistedJobFailed(.speakerReview, job: job)
                guard ownsReviewOperation(operation, recording: recording) else { return }
                await finishJob(job, completed: false)
            }
            return
        }
        switch session.origin {
        case .reprocessing: return
        case .pipeline:
            // Resume the held job's remaining pipeline INSIDE its own task so
            // `cancelProcessing()` can cancel it and the auto-drain can't launch a second
            // job while this resumed analysis is still running. `runAnalysisAndExport`
            // ends by calling `finishJob(_:)`, which tears the job down and drains.
            guard let job = operation.job, appState.processingJob === job else {
                appState.lastError = "The saved processing job is no longer active."
                return
            }
            do {
                try await persistCheckpoint(.speakerReviewCompleted, for: job)
                try requireReviewOwnership(operation, recording: recording)
            } catch {
                guard ownsReviewOperation(operation, recording: recording) else { return }
                appState.lastError = "Speaker review was saved, but its processing checkpoint failed."
                await markPersistedJobFailed(.persistence, job: job)
                guard ownsReviewOperation(operation, recording: recording) else { return }
                await finishJob(job, completed: false)
                return
            }
            guard ownsReviewOperation(operation, recording: recording) else { return }
            job.task = Task {
                let context: PrivacyTrace.Context
                if let saved = job.privacyContext { context = saved }
                else { context = await recording.privacyContext() }
                guard !Task.isCancelled, self.appState.processingJob === job else { return }
                await PrivacyTrace.$context.withValue(context) {
                    await self.runAnalysisAndExport(
                        recording: recording,
                        transcribe: session.transcribe,
                        summary: session.summary,
                        actionItems: session.actionItems,
                        tags: session.tags,
                        localAIAvailable: session.localAIAvailable,
                        perf: session.perf,
                        stopBeforeIntegrations: session.stopBeforeIntegrations
                    )
                }
            }
        case .rediarize:
            // A re-diarize from the transcript viewer isn't a pipeline job — no teardown.
            appState.speakerReviewCommit = SpeakerReviewCommit(
                recordingID: recording.id, token: UUID(), offerReanalysis: true)
        }
    }

    /// A false return means the review gate declined. Preparation failures throw
    /// so the viewer cannot silently commit a failed or superseded review.
    func presentReDiarizeReview(recording: Recording, turns: [DiarizedTurn],
                                embeddings: [String: [Float]], baseTranscript: RichTranscript,
                                validateSource: @escaping @MainActor @Sendable () throws -> Void) async throws -> Bool {
        try Task.checkCancellation()
        guard speakerReviewOperation == nil, appState.pendingSpeakerReview == nil,
              appState.processingJob?.recording !== recording else {
            throw NSError(domain: "SpeakerReview", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Finish the active speaker review or processing for this recording before trying again."])
        }
        let operation = ReviewOperation(recording: recording, job: nil)
        speakerReviewOperation = operation
        defer {
            operation.finish()
            if speakerReviewOperation === operation { speakerReviewOperation = nil }
        }
        let input = ProcessingPipeline.RediarizationReviewRequest(turns: turns, embeddings: embeddings,
            transcript: baseTranscript, mode: appSettings.speakerIdMode,
            roster: recording.participants + (recording.calendarEvent?.attendeeNames ?? []))
        let library = voiceLibraryStore
        let store = transcriptStore
        let prepared = try await processingPipeline.prepareRediarizationReview(input, loadLibrary: { await library.load() },
            save: { @MainActor rich in
                try self.requireReviewOwnership(operation, recording: recording)
                try validateSource()
                guard let url = operation.sidecarURL else { throw TranscriptStoreError.noSidecarURL }
                try await store.save(rich, to: url, replacing: baseTranscript)
                try self.requireReviewOwnership(operation, recording: recording)
                try validateSource()
            }, validateOwnership: { @MainActor in
                try self.requireReviewOwnership(operation, recording: recording)
                try validateSource()
            })
        try requireReviewOwnership(operation, recording: recording)
        try validateSource()
        guard let prepared else { return false }
        recording.richTranscript = prepared.transcript
        appState.pendingSpeakerReview = SpeakerReviewSession(recording: recording,
            masterAudioURL: recording.finalizedAudioURL, items: prepared.items,
            transcribe: false, summary: false, actionItems: false, tags: false,
            localAIAvailable: false, perf: TranscriptionPerf(), origin: .rediarize)
        SpeakerReviewWindowController.shared.show()
        sendReviewReadyNotification()
        Logger.transcription.info("Confirm-first re-diarize: holding \(prepared.items.count) speaker(s) for review")
        return true
    }

    /// Read-only access to the voice library for review UI (candidate chips).
    func loadVoiceLibrary() async -> VoiceLibrary { await voiceLibraryStore.load() }

    private func sendReviewReadyNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Confirm speakers"
        content.body = "Review who's who to finish processing this recording."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Retries AI analysis for a recording that already has a transcript on disk.
    /// Skips finalization and transcription — loads the saved transcript and reruns
    /// AI tasks, title generation, markdown export, and integration dispatch.
    /// Re-transcribe a recording that has finalized audio but no transcript yet — e.g.
    /// after the user Stopped a long transcription to free resources. Runs the full
    /// pipeline from transcription onward using the global auto-processing defaults.
    ///
    /// `recording` must carry `finalizedAudioURL` (the existing master m4a) so
    /// `ensureRecordingFinalized` early-returns and the audio is transcribed as-is —
    /// **never re-encoded through ffmpeg** (repeated encodes degrade quality). Passing the
    /// audio URL as `queuedAudioURL` lets `finishJob` sweep any leftover `.queue.json`
    /// sidecar a prior Stop wrote.
    static func retranscriptionProfileID(for recordingID: UUID, settings: AppSettings) -> UUID {
        // History retries use the saved manual baseline unless this recording
        // owns the current route. Another recording may still be awaiting review.
        if let owner = settings.automaticProfileRecordingID, owner != recordingID {
            settings.finishAutomaticRouting(for: owner)
        }
        return settings.activeProfile.id
    }

    func retranscribe(for recording: Recording) async {
        do { try await startReprocessing(for: recording, options: ReprocessingOptions(settings: appSettings, operation: .transcribe)) }
        catch { appState.lastError = error.localizedDescription }
    }

    func retryAIAnalysis(for recording: Recording) async {
        do { try await startReprocessing(for: recording, options: ReprocessingOptions(settings: appSettings, operation: .analysis)) }
        catch { appState.lastError = error.localizedDescription }
    }

    func startProcessing(transcribe: Bool, summary: Bool, actionItems: Bool, tags: Bool) {
        cancelPostRecordingAutomation()
        guard !captureCoordinator.isBusy, appState.showPostRecordingSheet, let recording = appState.currentRecording,
              let token = postRecordingAction.begin(recordingID: recording.id,
                  action: appState.processingJob == nil ? .process : .queue) else { return }
        // Only one job processes at a time. If one is already running, defer this recording
        // as auto-queued overflow — it drains automatically when the current job finishes,
        // and capture returns to idle so the user can immediately record the next meeting.
        if appState.processingJob != nil {
            Task { await self.queueForLater(recording: recording, token: token,
                                            transcribe: transcribe, summary: summary,
                                            actionItems: actionItems, tags: tags, autoQueued: true) }
            return
        }
        guard canLaunchProcessing(for: recording) else {
            postRecordingAction.finish(token: token, error: "Finish the active processing or queue operation first.")
            return
        }
        let profileID = recording.profileSelection.reviewProfileID(savedManualID: appSettings.activeProfileId)
        guard appSettings.profiles.contains(where: { $0.id == profileID }) else {
            postRecordingAction.finish(token: token, error: "Choose an available profile before processing.")
            return
        }
        appSettings.routeAutomatically(to: profileID, for: recording.id)
        let request = processingRequest(
            transcribe: transcribe,
            summary: summary,
            actionItems: actionItems,
            tags: tags,
            titleWasUserProvided: recording.titleWasUserProvided,
            autoResume: true
        )
        launchJob(recording: recording, persistedRequest: request, onPreparationFailure: { message in
            self.postRecordingAction.finish(token: token, error: message)
        }) { job in
            // The processing screen now owns progress; capture may proceed independently.
            self.recordingReviewSlot.dismiss(for: recording, actionToken: token)
            self.postRecordingAction.finish(token: token)
            await self.processRecording(job: job, transcribe: transcribe, summary: summary,
                                        actionItems: actionItems, tags: tags)
        }
    }

    /// Manual "Process Queue" button: drain everything, including user-deferred items.
    func startProcessingQueue() async {
        guard !queueMutationInProgress, !recoveryMaintenanceInProgress else { return }
        guard await setQueuePaused(false) else { return }
        drainAllQueued = true
        await drainQueueIfNeeded()
        await drainReprocessingQueue()
    }

    func cancelProcessing() async {
        if let job = appState.processingJob, job.reprocessingAttemptID != nil {
            await stopReprocessing(job)
            return
        }
        guard !processingCancellationInProgress, let job = appState.processingJob else { return }
        let token = UUID()
        let review = speakerReviewOperation.flatMap { $0.job === job ? $0 : nil }
        processingCancellationID = token
        processingCancellationInProgress = true
        // Freeze fallback intent before any await permits settings/profile changes.
        let request = job.persistedRecord?.request
        let fallback = QueueItem(id: job.id, transcribe: request?.transcribe ?? true,
            summary: request?.summary ?? appSettings.autoSummary,
            actionItems: request?.actionItems ?? appSettings.autoActionItems,
            tags: request?.tags ?? appSettings.autoTags,
            titleWasUserProvided: request?.titleWasUserProvided ?? job.recording.titleWasUserProvided,
            autoQueued: false, profileID: job.persistedRecord?.source.profileID ?? appSettings.activeProfile.id)
        job.task?.cancel()
        appState.processingJob = nil
        appState.liveInferenceText = nil
        for i in appState.processingSteps.indices {
            if case .inProgress = appState.processingSteps[i].status {
                appState.processingSteps[i].status = .failed("Cancelled by user")
            }
        }
        if appState.pendingSpeakerReview?.recording === job.recording {
            appState.pendingSpeakerReview = nil
            appState.recordingStatusNote = nil
            SpeakerReviewWindowController.shared.dismissForCancelledJob()
        }
        // Capture state belongs to a potentially concurrent recording. Only the
        // cancelled processing job participates in the actor's recovery handoff.
        let store = processingJobStore
        do {
            try await processingPipeline.cancelWorkflow(steps: .init(
                releaseResources: { @MainActor in await self.forceReleaseGPU() },
                waitForJob: { @MainActor in
                    await job.task?.value
                    await review?.waitForCompletion()
                },
                snapshot: { @MainActor in
                    try self.requireCancellationOwnership(token)
                    var source = self.makePersistedJob(id: job.id, recording: job.recording,
                        request: .init(transcribe: fallback.transcribe, summary: fallback.summary,
                            actionItems: fallback.actionItems, tags: fallback.tags,
                            titleWasUserProvided: fallback.titleWasUserProvided, autoResume: false)).source
                    source.profileID = fallback.profileID
                    return .init(jobID: job.id, source: source, fallbackRecord: job.persistedRecord,
                        queuedAudioURL: job.queuedAudioURL,
                        transcriptURL: job.recording.transcriptURL ?? Self.transcriptURL(for: job.recording),
                        fallbackQueueItem: fallback)
                }, loadRecord: { try await store.load(id: $0) },
                saveRecord: { try await store.save($0) },
                publishRecord: { @MainActor record in
                    try self.requireCancellationOwnership(token)
                    job.persistedRecord = record
                }, registerQueueFolder: { @MainActor folder in
                    try self.requireCancellationOwnership(token)
                    self.queueRefreshGeneration += 1
                    try await self.queueScheduleStore.rememberFolder(folder)
                    try self.requireCancellationOwnership(token)
                }, warning: { @MainActor warning in
                    try self.requireCancellationOwnership(token)
                    await self.holdQueueAfterCancellationFailure(warning)
                }, validateOwnership: { @MainActor in try self.requireCancellationOwnership(token) }))
        } catch {
            if processingCancellationID == token, appState.processingJob == nil {
                await holdQueueAfterCancellationFailure(.queue)
            }
        }
        guard processingCancellationID == token else { return }
        await refreshWorkQueue()
        guard processingCancellationID == token else { return }
        drainAllQueued = false
        processingCancellationID = nil
        processingCancellationInProgress = false
        appSettings.finishAutomaticRouting(for: job.recording.id)
        await drainQueueIfNeeded(completingCancellation: true)
        refreshPostRecordingProfileSelection()
    }

    private func requireCancellationOwnership(_ token: UUID) throws {
        // Cancelling the Stop caller cannot abandon recovery cleanup halfway through.
        guard processingCancellationID == token, processingCancellationInProgress,
              appState.processingJob == nil else { throw CancellationError() }
    }

    private func holdQueueAfterCancellationFailure(_ warning: ProcessingPipeline.CancellationWarning) async {
        // Establish the hold before the durable setting suspends or fails.
        queueSafetyHold = true
        queuePaused = true
        _ = await setQueuePaused(true, clearSafetyHold: false)
        queueSafetyHold = true
        queuePaused = true
        appState.lastError = warning == .journal
            ? "Processing stopped, but its recovery checkpoint couldn't be saved. Processing is paused for this session; check storage and retry."
            : "Processing stopped, but its retry queue couldn't be saved. Processing is paused for this session; check storage and retry."
    }

    func pickFileForTranscription() {
        guard recordingReviewSlot.canImport else { return }
        // Become a regular app so the open panel can take focus properly
        if !appSettings.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var contentTypes: [UTType] = [.audio, .mpeg4Audio, .wav, .mp3, .aiff]
        if let oggType = UTType(filenameExtension: "ogg") {
            contentTypes.append(oggType)
        }
        if let opusType = UTType(filenameExtension: "opus") {
            contentTypes.append(opusType)
        }
        if let flacType = UTType(filenameExtension: "flac") {
            contentTypes.append(flacType)
        }
        panel.allowedContentTypes = contentTypes
        panel.message = "Choose an audio file to transcribe"

        let response = panel.runModal()
        if !appSettings.showDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }

        guard response == .OK, let url = panel.url,
              let snapshot = recordingReviewSlot.snapshotForImport() else { return }

        // Copy off MainActor; reject the handoff if a newer import, capture or
        // review took over while the filesystem was busy.
        pickedImportTask?.cancel()
        pickedImportGeneration += 1
        let generation = pickedImportGeneration
        pickedImportTask = Task { @MainActor in
            defer { if generation == pickedImportGeneration { pickedImportTask = nil } }
            do {
                let prepared = try await importCoordinator.preparePickedFile(url, title: defaultMeetingTitle(from: nil))
                let recording = recordingForImport(prepared)
                guard !Task.isCancelled, generation == pickedImportGeneration,
                      recordingReviewSlot.acceptImport(recording, replacing: snapshot) else {
                    await importCoordinator.discard(prepared)
                    return
                }
                // Preserve immediate review, with duration filled in asynchronously.
                let duration = await importCoordinator.durationSeconds(for: url)
                if duration > 0 { recording.duration = duration }
            } catch is CancellationError {
                // The coordinator cleans up a cancelled copy before returning.
            } catch {
                if !Task.isCancelled, generation == pickedImportGeneration, recordingReviewSlot.canAcceptImport(snapshot) {
                    appState.lastError = "Couldn't read \(url.lastPathComponent). \(error.localizedDescription)"
                }
            }
        }
    }

    private func recordingForImport(_ prepared: ImportCoordinator.PreparedImport) -> Recording {
        let recording = Recording(date: prepared.date, fileURL: prepared.sourceURL,
            duration: prepared.duration, fileSize: prepared.fileSize,
            meetingTitleDraft: prepared.title, finalizedAudioURL: nil)
        recording.importSourceURL = prepared.stagedURL
        return recording
    }

    // MARK: - YouTube

    /// Download audio from a YouTube (or any yt-dlp-supported) URL, then show
    /// the post-recording sheet so the user can set options before processing.
    func loadYouTubeAudio(from urlString: String) async throws {
        guard let snapshot = recordingReviewSlot.snapshotForImport() else { throw RecordingReviewSlot.Failure.busy }
        let prepared = try await importCoordinator.prepareDownload(from: urlString)
        guard !Task.isCancelled,
              recordingReviewSlot.acceptImport(recordingForImport(prepared), replacing: snapshot) else {
            await importCoordinator.discard(prepared)
            throw CancellationError()
        }
    }

    // MARK: - Watched Folders

    /// Headlessly transcribe + analyze a file dropped into a watched folder, using the
    /// global auto-processing preferences. The user's original file is left untouched: it's
    /// copied into a temp location and imported (relocated) into the recordings folder via
    /// the same path as YouTube imports, so it lands in History with outputs in dBrief's
    /// folders rather than scattering sidecars next to the source.
    func processWatchedFile(_ sourceURL: URL) async {
        guard isIdle else { return }

        let prepared: ImportCoordinator.PreparedImport
        do {
            prepared = try await importCoordinator.prepareWatchedFile(sourceURL)
        } catch is CancellationError {
            return
        } catch {
            appState.lastError = "Watched folder: couldn't read \(sourceURL.lastPathComponent). \(error.localizedDescription)"
            return
        }

        // Preserve the post-probe idle check before launching any headless work.
        guard isIdle, !Task.isCancelled else {
            await importCoordinator.discard(prepared)
            return
        }
        let recording = recordingForImport(prepared)
        guard canLaunchProcessing(for: recording) else {
            await importCoordinator.discard(prepared)
            return
        }

        // Headless: run as a background job (no capture slot, no post-recording sheet) and
        // await completion so the watched-folder poller stays serial (its `isIdle` gate also
        // defers new files while this job runs).
        let request = processingRequest(
            transcribe: appSettings.autoTranscribe,
            summary: appSettings.autoSummary && appSettings.autoTranscribe,
            actionItems: appSettings.autoActionItems && appSettings.autoTranscribe,
            tags: appSettings.autoTags && appSettings.autoTranscribe,
            titleWasUserProvided: recording.titleWasUserProvided,
            autoResume: true
        )
        let job = launchJob(recording: recording, persistedRequest: request) { job in
            await self.processRecording(
                job: job,
                transcribe: self.appSettings.autoTranscribe,
                summary: self.appSettings.autoSummary && self.appSettings.autoTranscribe,
                actionItems: self.appSettings.autoActionItems && self.appSettings.autoTranscribe,
                tags: self.appSettings.autoTags && self.appSettings.autoTranscribe
            )
        }
        await job.task?.value
    }

    func skipProcessing() async {
        cancelPostRecordingAutomation()
        guard !captureCoordinator.isBusy, appState.showPostRecordingSheet, let recording = appState.currentRecording,
              let token = postRecordingAction.begin(recordingID: recording.id, action: .skip) else { return }
        defer {
            postRecordingAction.finish(token: token)
            if !appState.showPostRecordingSheet { appSettings.finishAutomaticRouting(for: recording.id) }
        }
        do {
            try await finalizePostRecording(recording, token: token)
        } catch {
            guard recordingReviewSlot.ownsAction(for: recording, token: token) else { return }
            postRecordingAction.finish(token: token, error: error.localizedDescription)
            appState.lastError = error.localizedDescription
            return
        }
        guard recordingReviewSlot.dismiss(for: recording, actionToken: token) else { return }
        appState.recordingState = .idle
    }

    /// Discards the current post-recording recording: removes its on-disk audio
    /// (the captured scratch tracks if not yet finalized, otherwise the finalized
    /// master + sidecars) and returns to idle without processing. Backs the
    /// post-recording sheet's Delete action.
    func discardRecording() async {
        cancelPostRecordingAutomation()
        guard !captureCoordinator.isBusy, appState.showPostRecordingSheet, let recording = appState.currentRecording,
              let token = postRecordingAction.begin(recordingID: recording.id, action: .delete) else { return }
        defer { postRecordingAction.finish(token: token) }
        var urls = [recording.fileURL]
        if let tracks = recording.capturedTracks {
            urls.append(contentsOf: [tracks.systemURL, tracks.micURL].compactMap { $0 })
        }
        if let finalized = recording.finalizedAudioURL { urls.append(finalized) }
        if let metadata = recording.metadataURL { urls.append(metadata) }
        urls.append(contentsOf: recording.segmentAudioURLs)
        let input = ProcessingPipeline.DiscardRequest(recordingID: recording.id,
            recoveryManifestURL: recording.recoveryManifestURL,
            audioURL: recording.finalizedAudioURL ?? recording.fileURL,
            finalized: recording.finalizedAudioURL != nil, knownFiles: urls,
            pendingReceiptURL: recording.privacyScope?.pendingReceiptURL)
        await processingPipeline.discardRecordingFiles(input, store: recording.privacyScope?.store ?? .shared)
        guard postRecordingAction.token == token, postRecordingAction.recordingID == recording.id,
              appState.currentRecording === recording else { return }
        if recording.recoveryManifestURL == input.recoveryManifestURL { recording.recoveryManifestURL = nil }
        recording.capturedTracks = nil
        appSettings.finishAutomaticRouting(for: recording.id)
        appState.currentRecording = nil
        appState.showPostRecordingSheet = false
        appState.recordingState = .idle
    }

    /// Finalizes the current recording and writes a `.queue.json` sidecar for later
    /// processing. `autoQueued` marks overflow (a recording finished while a job was
    /// running) — those drain automatically; explicit "Queue for later" (autoQueued:false)
    /// waits for the manual "Process Queue" button. Returns capture to idle either way.
    func queueForLater(
        transcribe: Bool,
        summary: Bool,
        actionItems: Bool,
        tags: Bool,
        autoQueued: Bool = false
    ) async {
        cancelPostRecordingAutomation()
        guard !captureCoordinator.isBusy, appState.showPostRecordingSheet, let recording = appState.currentRecording,
              let token = postRecordingAction.begin(recordingID: recording.id, action: .queue) else { return }
        await queueForLater(recording: recording, token: token, transcribe: transcribe,
            summary: summary, actionItems: actionItems, tags: tags, autoQueued: autoQueued)
    }

    private func finalizePostRecording(_ recording: Recording, token: UUID) async throws {
        let state = postRecordingAction
        try await ensureRecordingFinalized(recording: recording) { progress in
            Task { @MainActor in state.updateProgress(progress, token: token) }
        }
    }

    private func queueForLater(
        recording: Recording, token: UUID, transcribe: Bool, summary: Bool,
        actionItems: Bool, tags: Bool, autoQueued: Bool
    ) async {
        defer { postRecordingAction.finish(token: token) }
        // Finalization suspends; another worker can finish and release its route
        // before the marker is written. Retain the choice made at invocation.
        let profileID = recording.profileSelection.retainedManualChoice(savedManualID: appSettings.activeProfileId)
            ?? recording.profileSelection.appliedID ?? appSettings.activeProfile.id
        do {
            try await finalizePostRecording(recording, token: token)
        } catch {
            guard postRecordingAction.token == token, appState.currentRecording === recording else { return }
            postRecordingAction.finish(token: token, error: error.localizedDescription)
            appState.lastError = error.localizedDescription
            return
        }

        let item = QueueItem(
            transcribe: transcribe,
            summary: summary && transcribe,
            actionItems: actionItems && transcribe,
            tags: tags && transcribe,
            titleWasUserProvided: recording.titleWasUserProvided,
            autoQueued: autoQueued,
            profileID: profileID
        )

        do {
            guard postRecordingAction.token == token, postRecordingAction.recordingID == recording.id,
                  appState.currentRecording === recording, appState.showPostRecordingSheet,
                  !recoveryMaintenanceInProgress else { return }
            queueEnqueueInProgress = true
            defer { queueEnqueueInProgress = false }
            try await saveQueueItem(item, for: recording)
            guard postRecordingAction.token == token, appState.currentRecording === recording,
                  appState.showPostRecordingSheet else { return }
        } catch {
            guard postRecordingAction.token == token, appState.currentRecording === recording else { return }
            postRecordingAction.finish(token: token, error: error.localizedDescription)
            appState.lastError = error.localizedDescription
            return
        }

        appState.showPostRecordingSheet = false
        appState.recordingState = .idle
        appState.currentRecording = nil
        await refreshWorkQueue()
        appSettings.finishAutomaticRouting(for: recording.id)
        // Auto-queued overflow starts immediately if no job is currently running.
        await drainQueueIfNeeded()
    }

    func purgeLocalWhisperModel() async throws {
        try await modelDownloadCoordinator.purge(.whisper)
    }

    func purgeLocalQwenModel() async throws {
        try await modelDownloadCoordinator.purge(.gemma)
    }

    func purgeLocalParakeetModel() async throws {
        try await modelDownloadCoordinator.purge(.parakeet)
    }

    /// True when models may be downloaded (no active recording/processing that
    /// would contend for the GPU mutex and the shared state stream).
    var canDownloadModels: Bool {
        !captureCoordinator.isBusy && appState.recordingState == .idle && appState.processingJob == nil
    }

    /// True when no recording AND no processing is in flight — safe for the watched-folder
    /// poller to start a headless transcription. (Distinct from `AppState.isIdle`, which is
    /// capture-only and drives the Record button.)
    var isIdle: Bool {
        !captureCoordinator.isBusy && appState.recordingState == .idle && appState.processingJob == nil
            && !appState.showPostRecordingSheet && !postRecordingAction.isBusy
    }

    /// Fetch the list of available WhisperKit model variants from HuggingFace,
    /// routed through the helper process. Returns [] on failure (caller falls back).
    func fetchAvailableWhisperModels() async -> [String] {
        await modelDownloadCoordinator.availableWhisperModels()
    }

    /// Best-effort check for whether the model selected for `kind` is cached.
    func isModelCached(_ kind: LocalModelKind) async -> Bool {
        await modelDownloadCoordinator.isCached(modelDownloadRequest(kind))
    }

    /// Start downloading the selected model. The coordinator owns its lifecycle;
    /// the manager keeps the existing recording/processing admission policy.
    func downloadModel(_ kind: LocalModelKind, forceRedownload: Bool = false) {
        guard canDownloadModels else { return }
        modelDownloadCoordinator.start(modelDownloadRequest(kind), forceRedownload: forceRedownload)
    }

    func cancelDownload(_ kind: LocalModelKind) {
        modelDownloadCoordinator.cancel(kind)
    }

    /// Recording start still cancels every owned download before capture setup.
    func cancelAllActiveDownloads() {
        modelDownloadCoordinator.cancelAll()
    }

    private func modelDownloadRequest(_ kind: LocalModelKind) -> ModelDownloadCoordinator.Request {
        switch kind {
        case .whisper:
            .whisper(WhisperRuntimeConfig(modelName: appSettings.whisperModelName,
                language: appSettings.transcriptionLanguage.isEmpty ? nil : appSettings.transcriptionLanguage,
                diarizationEnabled: false))
        case .parakeet:
            .parakeet(variant: appSettings.parakeetModelVariant)
        case .gemma:
            .gemma
        }
    }

    /// Called by MemoryPressureMonitor when system memory pressure is detected.
    /// Unloads all local AI models to free memory.
    func handleMemoryPressure() async {
        await localAIPluginService.purgeModelsOnMemoryPressure()
        try? await parakeetService.purgeModels()
    }

    /// Force-release all Metal/GPU resources before app termination.
    func forceReleaseGPU() async {
        await localAIPluginService.forceUnload()
        try? await parakeetService.purgeModels()
    }

    func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Private

    private func appendAIStep(_ name: String) -> Int {
        let index = appState.processingSteps.count
        appState.processingSteps.append(ProcessingStep(name: name, status: .inProgress))
        return index
    }

    private func labelForSummary(engine: AppSettings.AIEngine) -> String {
        switch engine {
        case .appleIntelligence: "Generating summary (Apple Intelligence)"
        case .qwenLocal: "Generating summary (Gemma 4 E4B local)"
        case .remoteEndpoint: "Generating summary"
        case .localCLI: "Generating summary (Local CLI)"
        }
    }

    private func labelForActionItems(engine: AppSettings.AIEngine) -> String {
        switch engine {
        case .appleIntelligence: "Extracting action items (Apple Intelligence)"
        case .qwenLocal: "Extracting action items (Gemma 4 E4B local)"
        case .remoteEndpoint: "Extracting action items"
        case .localCLI: "Extracting action items (Local CLI)"
        }
    }

    private func labelForTags(engine: AppSettings.AIEngine) -> String {
        switch engine {
        case .appleIntelligence: "Analyzing tags (Apple Intelligence)"
        case .qwenLocal: "Analyzing tags & sentiment (Gemma 4 E4B local)"
        case .remoteEndpoint: "Analyzing tags & sentiment"
        case .localCLI: "Analyzing tags & sentiment (Local CLI)"
        }
    }

    /// Observable façade for the actor's shared analysis stage. Snapshot settings
    /// after loading reviewed speaker names, and publish only to the owning job.
    private func runPipelineAnalysis(
        job: ProcessingJob, summary: Bool, actionItems: Bool, tags: Bool,
        localAIAvailable: Bool
    ) async throws -> ProcessingPipeline.AnalysisOutput {
        try requireProcessingOwnership(job)
        let recording = job.recording
        if recording.richTranscript == nil {
            let rich = try? await transcriptStore.load(for: recording)
            try requireProcessingOwnership(job)
            if recording.richTranscript == nil { recording.richTranscript = rich }
        }
        guard let transcription = recording.transcription else { throw TranscriptStoreError.noSidecarURL }
        let engine = appSettings.effectiveAIEngine
        appState.preflightWarning = Self.preflightCheck(engine: engine,
            hasRemoteEndpoint: appSettings.effectiveDefaultAIEndpoint != nil)
        let summaryIndex = summary ? appendAIStep(labelForSummary(engine: engine)) : nil
        let actionsIndex = actionItems ? appendAIStep(labelForActionItems(engine: engine)) : nil
        let tagsIndex = tags ? appendAIStep(labelForTags(engine: engine)) : nil
        let fields = Set<ProcessingPipeline.AnalysisField>(
            (summary ? [.summary] : []) + (actionItems ? [.actionItems] : []) + (tags ? [.tags] : []))
        let appleUnavailable: String? = {
            #if canImport(FoundationModels)
            guard #available(macOS 26, *) else { return "Apple Intelligence requires macOS 26+." }
            return localAIAvailable ? nil : "Apple Intelligence is unavailable. Ensure it is enabled and your System + Siri languages match."
            #else
            return "Apple Intelligence is unavailable in this build."
            #endif
        }()
        let input = ProcessingPipeline.AnalysisRequest(transcription: transcription,
            speakerNames: Dictionary((recording.richTranscript?.speakerLabels ?? []).map { ($0.id, $0.displayName) },
                                     uniquingKeysWith: { first, _ in first }),
            participants: recording.participants, calendarEvent: recording.calendarEvent,
            engine: engine, endpoint: appSettings.effectiveDefaultAIEndpoint, fields: fields,
            outputLanguage: appSettings.outputLanguage,
            vocabulary: appSettings.effectiveCustomVocabulary.joined(separator: ", "),
            guidance: .init(summary: appSettings.effectiveSummaryPrompt, actionItems: appSettings.effectiveActionItemsPrompt,
                            tags: appSettings.effectiveTagsPrompt),
            localCLIConfig: appSettings.localCLIConfig, appleUnavailableReason: appleUnavailable)
        let progress = ProcessingStepProgress(appState: appState, job: job,
            stepIndex: firstNonNil(summaryIndex, actionsIndex, tagsIndex))
        defer { progress.invalidate() }
        do {
            let output = try await MLProgress.$sink.withValue(progress.handler()) {
                try await processingPipeline.analyze(input,
                    using: .live(ai: aiService, plugin: localAIPluginService, cli: localCLIService),
                    onEvent: { [weak self] event in
                        await self?.applyAnalysisEvent(event, job: job, summaryIndex: summaryIndex,
                                                      actionsIndex: actionsIndex, tagsIndex: tagsIndex, modelName: input.modelName)
                    })
            }
            try requireProcessingOwnership(job)
            return output
        } catch {
            // Publish field errors only. The actor workflow owns failure recovery
            // and the terminal decision, including independent backend cancellation.
            try requireProcessingOwnership(job)
            markFailed(summaryIndex, error.localizedDescription)
            markFailed(actionsIndex, error.localizedDescription)
            markFailed(tagsIndex, error.localizedDescription)
            throw error
        }
    }

    private func applyAnalysisEvent(_ event: ProcessingPipeline.AnalysisEvent, job: ProcessingJob,
                                    summaryIndex: Int?, actionsIndex: Int?, tagsIndex: Int?, modelName: String?) {
        guard !Task.isCancelled, appState.processingJob === job else { return }
        let recording = job.recording
        recording.applyAnalysisField(event, modelName: modelName)
        switch event {
        case .summary:
            if let summaryIndex { markCompleted(summaryIndex) }
        case .actionItems:
            if let actionsIndex { markCompleted(actionsIndex) }
        case .tags:
            if let tagsIndex { markCompleted(tagsIndex) }
        case .titleConcept(let value): applyGeneratedTitle(value, to: recording)
        case .liveText(let value): appState.liveInferenceText = value
        case .failed(let field, let message):
            let index: Int? = switch field {
            case .summary: summaryIndex
            case .actionItems: actionsIndex
            case .tags: tagsIndex
            }
            markFailed(index, message)
        }
    }

    /// Drive the transcription step's determinate progress bar + "time left" label.
    /// Ticks once a second: prefers true segment coverage (WhisperKit streaming),
    /// otherwise estimates from the model's historical realtime ratio. Stays silent
    /// (leaving the download/load bar untouched) until `job.transcriptionStartedAt`
    /// is set, i.e. actual transcription has begun. Cancel it when the step ends.
    func withTranscriptionProgress<T>(
        job: ProcessingJob, stepIndex: Int,
        settings: ProcessingPipeline.TranscriptionSettings,
        operation: () async throws -> T
    ) async throws -> T {
        try requireProcessingOwnership(job)
        switch settings.engine {
        case .appleSpeech, .remoteEndpoint: job.transcriptionStartedAt = Date()
        case .localWhisper, .parakeetLocal: job.transcriptionStartedAt = nil
        }
        let ticker = startTranscriptionETATicker(job: job, stepIndex: stepIndex,
            audioDuration: job.recording.duration, settings: settings)
        defer {
            ticker.cancel()
            job.transcriptionStartedAt = nil
        }
        return try await operation()
    }

    private func startTranscriptionETATicker(
        job: ProcessingJob,
        stepIndex: Int,
        audioDuration: TimeInterval,
        settings: ProcessingPipeline.TranscriptionSettings
    ) -> Task<Void, Never> {
        let progress = ProcessingStepProgress(appState: appState, job: job, stepIndex: stepIndex)
        return Task { @MainActor [weak self] in
            defer { progress.invalidate() }
            guard let self else { return }
            // Prefer the model's measured realtime ratio; on a first-ever run there's no
            // history yet (and any pre-fix 0-duration records are excluded), so fall back
            // to a conservative per-engine default. Without it the bar has no signal until
            // segments stream — and engines that deliver segments in a late batch (observed:
            // WhisperKit on a multi-hour in-memory file) leave the bar pinned at 0 for the
            // whole run. The default deliberately under-estimates speed so the bar trails
            // real progress (finishing a touch early) rather than racing to 99% and stalling.
            let ratio = await self.modelPerformanceStore
                .averageTranscriptionRealtime(forModel: settings.modelDisplayName)
                ?? self.fallbackRealtimeRatio(for: settings.engine)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard progress.isCurrent else { return }
                // Before transcription proper (model download/load) the bar is owned by
                // applyPluginState's download progress — don't fight it.
                guard let startedAt = job.transcriptionStartedAt else { continue }
                let estimate = TranscriptionProgressEstimate.compute(
                    audioDuration: audioDuration,
                    realtimeRatio: ratio,
                    elapsed: Date().timeIntervalSince(startedAt),
                    // Furthest-decoded end, not the last-appended segment: with VAD +
                    // concurrent workers, segments stream out of order, so `.last` lags
                    // true coverage and would inflate the remaining-time estimate.
                    latestSegmentEnd: job.progressiveSegments.map(\.end).max()
                )
                progress.update { step, _ in
                    if let fraction = estimate.progress { step.progress = fraction }
                    step.detail = estimate.remaining
                }
            }
        }
    }

    /// Conservative audio-seconds-per-wall-second used to animate the transcription
    /// bar before any real timing history exists for the active model. Intentionally
    /// on the low side of typical Apple-Silicon throughput so the bar under-promises
    /// (trails actual progress) instead of overshooting to 99% and sitting there; once
    /// a session is recorded, `averageTranscriptionRealtime` supersedes these.
    private func fallbackRealtimeRatio(for engine: AppSettings.TranscriptionEngine) -> Double {
        switch engine {
        case .localWhisper: return 10   // large-v3 turbo measures ~16×; smaller/quantized less
        case .parakeetLocal: return 20  // TDT is markedly faster than Whisper
        case .appleSpeech: return 5
        case .remoteEndpoint: return 3  // network-bound and highly variable
        }
    }

    private func withPluginStepAdapter<T>(
        progress: ProcessingStepProgress,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await MLProgress.$sink.withValue(progress.handler(parakeet: false)) {
            try await operation()
        }
    }

    private func withParakeetStepAdapter<T>(
        progress: ProcessingStepProgress,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await MLProgress.$sink.withValue(progress.handler(parakeet: true)) {
            try await operation()
        }
    }

    private func firstNonNil(_ values: Int?...) -> Int {
        for value in values {
            if let value {
                return value
            }
        }
        return 0
    }

    private func markCompleted(_ stepIndex: Int) {
        guard appState.processingSteps.indices.contains(stepIndex) else { return }
        appState.processingSteps[stepIndex].status = .completed
    }

    private func markFailed(_ stepIndex: Int?, _ message: String) {
        guard let stepIndex, appState.processingSteps.indices.contains(stepIndex) else { return }
        appState.processingSteps[stepIndex].status = .failed(message)
    }

    // MARK: - Model performance logging

    /// Best-available display title for the per-recording Benchmark list: the
    /// AI-generated title (sans its leading "YYYY-MM-DD - " date prefix) when set,
    /// else the user's draft title, else the audio filename.
    private func performanceLabel(for recording: Recording) -> String {
        if let generated = recording.generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !generated.isEmpty {
            // Strip a leading ISO-date prefix ("2026-06-17 - ") that persistGeneratedTitle adds.
            if let range = generated.range(of: #"^\d{4}-\d{2}-\d{2}\s*-\s*"#, options: .regularExpression) {
                let stripped = String(generated[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty { return stripped }
            }
            return generated
        }
        let draft = recording.meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty { return draft }
        return recording.fileURL.deletingPathExtension().lastPathComponent
    }

    /// Append a performance record for the session, if either pass produced
    /// timing. Fire-and-forget — never blocks or fails the pipeline.
    private func logModelPerformance(
        label: String? = nil,
        transcriptionModel: String?,
        audioDuration: TimeInterval?,
        transcriptionTime: TimeInterval?,
        inferenceTime: TimeInterval?,
        diarizationTime: TimeInterval? = nil,
        finalizationTime: TimeInterval? = nil,
        aiModel: String?,
        aiTime: TimeInterval?,
        spellCorrectionTime: TimeInterval? = nil,
        titleGenerationTime: TimeInterval? = nil
    ) {
        guard transcriptionTime != nil || aiTime != nil else { return }
        let hasTx = transcriptionTime != nil
        let record = ModelPerformanceRecord(
            label: label,
            transcriptionModel: hasTx ? transcriptionModel : nil,
            audioDuration: hasTx ? audioDuration : nil,
            transcriptionTime: transcriptionTime,
            inferenceTime: hasTx ? inferenceTime : nil,
            diarizationTime: hasTx ? diarizationTime : nil,
            finalizationTime: finalizationTime,
            aiModel: aiTime != nil ? aiModel : nil,
            aiTime: aiTime,
            spellCorrectionTime: hasTx ? spellCorrectionTime : nil,
            titleGenerationTime: aiTime != nil ? titleGenerationTime : nil
        )
        Task { await modelPerformanceStore.append(record) }
    }

    /// Result of the transcription step: the (cleaned, optionally spell-corrected)
    /// transcript plus the wall-clock spent in the vocabulary spell-correction pass
    /// (nil when no vocabulary was set, so the Benchmark breakdown can show it apart
    /// from the transcription model/overhead).
    func transcribeRecordingAudio(
        recording: Recording,
        stepIndex: Int,
        settings: ProcessingPipeline.TranscriptionSettings
    ) async throws -> ProcessingPipeline.TranscriptionOutput {
        guard let owner = appState.processingJob, owner.recording === recording else { throw CancellationError() }
        let correct: (@Sendable (TranscriptionResult) async -> TranscriptionResult)?
        if settings.spelling.terms.isEmpty {
            correct = nil
        } else {
            let speller = TranscriptSpellingService(localPlugin: localAIPluginService)
            correct = { await speller.correct($0, request: settings.spelling) }
        }
        let result = try await withTranscriptionProgress(job: owner, stepIndex: stepIndex, settings: settings) {
            try await processingPipeline.transcribe(
                .init(audioURL: recording.fileURL, segmentURLs: recording.segmentAudioURLs),
                options: settings.cleanup,
                using: { @MainActor request in
                    guard !Task.isCancelled, self.appState.processingJob === owner else {
                        throw CancellationError()
                    }
                    return try await self.transcribeSingleAudioFile(request.url, job: owner, stepIndex: stepIndex,
                        segmentIndex: request.segmentIndex, segmentCount: request.segmentCount, settings: settings)
                }, correct: correct,
                onEvent: { @MainActor event in
                    guard !Task.isCancelled, self.appState.processingJob === owner,
                          self.appState.processingSteps.indices.contains(stepIndex) else { return }
                    switch event {
                    case .transcribingSegment(let index, let count):
                        self.appState.processingSteps[stepIndex].name = "Transcribing audio (segment \(index)/\(count))"
                    case .correctingVocabulary:
                        self.appState.processingSteps[stepIndex].name = "Correcting vocabulary…"
                        self.appState.processingJob?.transcriptionStartedAt = nil
                        self.appState.processingSteps[stepIndex].progress = nil
                        self.appState.processingSteps[stepIndex].detail = nil
                    }
                })
        }
        try Task.checkCancellation()
        guard appState.processingJob === owner else { throw CancellationError() }
        return result
    }

    private func transcribeSingleAudioFile(
        _ url: URL,
        job: ProcessingJob,
        stepIndex: Int,
        segmentIndex: Int?,
        segmentCount: Int?,
        settings: ProcessingPipeline.TranscriptionSettings
    ) async throws -> TranscriptionResult {
        try requireProcessingOwnership(job)
        let progress = ProcessingStepProgress(appState: appState, job: job, stepIndex: stepIndex)
        defer { progress.invalidate() }
        switch settings.engine {
        case .appleSpeech:
            let language = settings.language
            // macOS 26+ uses the modern SpeechAnalyzer (better accuracy, word-level
            // timestamps); older systems and unsupported locales fall back to the
            // legacy SFSpeechRecognizer-based service.
            if #available(macOS 26, *) {
                let locale = language.isEmpty ? Locale.current : Locale(identifier: language)
                let supported = await AppleSpeechAnalyzerService.supports(locale: locale)
                try requireProcessingOwnership(job)
                if supported {
                    return try await AppleSpeechAnalyzerService().transcribe(
                        fileURL: url,
                        language: language,
                        status: { statusText in
                            Task { @MainActor in progress.update { step, _ in step.name = statusText } }
                        }
                    )
                }
            }
            return try await localTranscriptionService.transcribe(
                fileURL: url,
                language: language
            )
        case .localWhisper:
            let whisperConfig = settings.whisper
            return try await withPluginStepAdapter(progress: progress) {
                // Custom vocabulary is intentionally NOT passed to Whisper as a
                // decoder prompt: an off-topic (or even on-topic) prompt can make
                // Whisper emit blank output for most windows, silently dropping the
                // bulk of the transcript. Vocabulary spelling is instead applied as
                // a reliable post-step (TranscriptSpellingService) in
                // transcribeRecordingAudio. See WhisperKitTranscriptionService notes.
                //
                // For segmented recordings, keep the Whisper/SpeakerKit models
                // resident in the helper until the last segment so each 30-min
                // part doesn't pay a full model reload.
                try await self.localAIPluginService.transcribe(
                    fileURL: url,
                    initialPrompt: nil,
                    whisperConfig: whisperConfig,
                    unloadAfter: segmentIndex == nil || segmentIndex == segmentCount
                )
            }
        case .parakeetLocal:
            return try await withParakeetStepAdapter(progress: progress) {
                try await self.parakeetService.transcribe(
                    fileURL: url,
                    language: settings.parakeetLanguage,
                    modelVariant: settings.parakeetModelVariant,
                    diarize: settings.diarize
                )
            }
        case .remoteEndpoint:
            guard let endpoint = settings.endpoint else {
                throw TranscriptionError.invalidEndpoint
            }

            let segmentLabel: String
            if let segmentIndex, let segmentCount {
                segmentLabel = "segment \(segmentIndex)/\(segmentCount)"
            } else {
                segmentLabel = "audio"
            }
            return try await transcriptionService.transcribe(
                fileURL: url,
                endpoint: endpoint,
                language: settings.language,
                // Custom vocabulary is intentionally NOT sent as the ASR prompt:
                // the only remote consumers of initialPrompt are Whisper-family
                // servers (OpenAI-compatible `prompt` / whisper-asr `initial_prompt`),
                // which share Whisper's prompt fragility (it can blank out large
                // stretches of audio). Deepgram/ElevenLabs ignore it entirely.
                // Vocabulary spelling is applied uniformly post-transcription via
                // TranscriptSpellingService in transcribeRecordingAudio.
                initialPrompt: "",
                diarize: settings.diarize,
                chunking: settings.chunking,
                progress: { chunk in
                    Task { @MainActor in
                        progress.update { step, _ in
                            step.name = "Transcribing \(segmentLabel) (chunk \(chunk.current)/\(chunk.total))"
                        }
                    }
                }
            )
        }
    }

    private func ensureRecordingFinalized(
        recording: Recording,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let context: PrivacyTrace.Context
        if let current = PrivacyTrace.context, current.recordingID == recording.id { context = current }
        else { context = await recording.privacyContext() }
        try await PrivacyTrace.$context.withValue(context) {
            try Task.checkCancellation()
            if recording.finalizedAudioURL == nil {
                try await PrivacyTrace.perform(.init(stage: .finalization, data: [.recordingAudio],
                                                     destination: .local(provider: .fileSystem))) {
                    try await finalizeRecordingAudio(recording: recording, onProgress: onProgress)
                }
            } else {
                try await finalizeRecordingAudio(recording: recording, onProgress: onProgress)
            }
            await recording.bindPrivacyReceipt()
        }
    }

    private func finalizeRecordingAudio(
        recording: Recording,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let recovery = ProcessingPipeline.FinalizationRecovery.capture(id: recording.id, startedAt: recording.date,
            manifestURL: recording.recoveryManifestURL, tracks: recording.capturedTracks)
        let source: ProcessingPipeline.FinalizationSource
        let finalize: @Sendable () async throws -> RecordingFinalizationResult
        if let finalized = recording.finalizedAudioURL {
            source = .existing(finalized)
            finalize = { throw CancellationError() } // Existing audio never invokes the finalizer.
        } else {
            if recording.meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recording.meetingTitleDraft = defaultMeetingTitle(from: recording.associatedApp)
            }
            // Review actions can finalize alongside another worker. Freeze this
            // recording's destination without changing that worker's live settings.
            let profile: MeetingProfile
            if appState.showPostRecordingSheet, appState.currentRecording === recording {
                let id = recording.profileSelection.reviewProfileID(savedManualID: appSettings.activeProfileId)
                guard let selected = appSettings.profiles.first(where: { $0.id == id }) else {
                    throw NSError(domain: "RecordingManager", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Choose an available profile before saving this recording."])
                }
                profile = selected
            } else {
                profile = appSettings.activeProfile
            }
            let baseFolder = appSettings.resolvedFolderURL(overridePath: profile.overrides.recordingFolderPath,
                                                           fallback: appSettings.recordingFolderURL)
            let engine = profile.overrides.transcriptionEngine ?? appSettings.transcriptionEngine
            let segmentationEnabled = engine != .localWhisper && engine != .parakeetLocal
            let snapshot = RecordingFinalizationSnapshot(recording: recording)
            let finalizer = recordingFinalizer
            if let importSource = recording.importSourceURL {
                source = .imported
                finalize = {
                    try await finalizer.importExistingAudio(sourceURL: importSource, snapshot: snapshot,
                        baseFolder: baseFolder, segmentationEnabled: segmentationEnabled)
                }
            } else {
                let tracks = recording.capturedTracks ?? CapturedTracks(systemURL: nil, micURL: recording.fileURL)
                let echoSuppression = recording.echoSuppressionApplied
                source = .capture(tracks)
                finalize = {
                    try await finalizer.finalize(tracks: tracks, snapshot: snapshot, baseFolder: baseFolder,
                        segmentationEnabled: segmentationEnabled, echoSuppressionEnabled: echoSuppression,
                        onProgress: onProgress)
                }
            }
        }
        let input = ProcessingPipeline.FinalizationRequest(recordingID: recording.id, duration: recording.duration,
            source: source, recovery: recovery)
        try await processingPipeline.finalizeAudio(input, steps: .init(finalize: finalize,
            adopt: { @MainActor result in
                // The durable result must be adopted even if Stop arrived after
                // the finalizer consumed scratch files. Stop awaits this handoff.
                if case .imported = source { recording.importSourceURL = nil }
                if case .capture = source { recording.capturedTracks = nil }
                recording.fileURL = result.masterAudioURL
                recording.finalizedAudioURL = result.masterAudioURL
                recording.segmentAudioURLs = result.segmentAudioURLs
                recording.metadataURL = result.metadataURL
                recording.finalizationWarnings = result.warnings
            }, measured: { @MainActor facts in
                guard recording.finalizedAudioURL == facts.url else { return }
                if let size = facts.fileSize { recording.fileSize = size }
                if let duration = facts.duration { recording.duration = duration }
            }, recoveryCompleted: { @MainActor url in
                if recording.recoveryManifestURL == url { recording.recoveryManifestURL = nil }
            }))
    }

    private func defaultMeetingTitle(from associatedApp: String?) -> String {
        let candidate = associatedApp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if candidate.isEmpty { return "meeting" }
        return candidate
    }

    private func sendCompletionNotification(fileName: String, failed: Int) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        if failed == 0 {
            content.title = "Processing Complete"
            content.body = "\(fileName) has been transcribed and analyzed."
        } else {
            content.title = "Processing Finished"
            content.body = "\(fileName) — \(failed) step(s) failed."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
    private static func dateOnlyString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Persist AI analysis to `<base>.insights.json` so the transcript window can
    /// display and edit it later. No-op when there is no summary to save.
    /// Writes the AI-generated title back into the recording's metadata `.json`
    /// sidecar so the transcript browser can show it (the audio file is never
    /// renamed — it's referenced by the sidecar, segments, and markdown links).
    /// No-op when there's no generated title or sidecar. See #71.
    /// Whether AI-generated titles should replace the display title for this recording.
    /// False when the user supplied their own title (see `Recording.titleWasUserProvided` /
    /// `PostRecordingSheet.isCustomTitle`), so a typed title is never overwritten.
    private func shouldGenerateTitle(for recording: Recording) -> Bool {
        !recording.titleWasUserProvided
    }

    /// Set the AI's inline title concept as the recording's generated title (with the shared
    /// "YYYY-MM-DD - " prefix), unless the user supplied their own title or the concept is blank.
    private func applyGeneratedTitle(_ rawConcept: String, to recording: Recording) {
        guard shouldGenerateTitle(for: recording) else { return }
        let concept = rawConcept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !concept.isEmpty else { return }
        recording.generatedTitle = "\(Self.dateOnlyString(recording.date)) - \(concept)"
    }

    private func persistGeneratedTitle(for recording: Recording, job: ProcessingJob?) async {
        let title = recording.generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return }
        await updateMetadataSidecar(.generatedTitle(title), for: recording, job: job, describing: "generated title")
    }

    private func persistProcessingCompletion(_ completion: ProcessingCompletionStamp, for job: ProcessingJob) async throws {
        try Task.checkCancellation()
        guard appState.processingJob === job else { throw CancellationError() }
        let recording = job.recording
        guard let audio = recording.finalizedAudioURL else { throw RecordingCompletionStore.Failure.recordingUnavailable }
        let fallback = RecordingMetadataPayload(recordingID: recording.id,
            dateISO8601: ISO8601DateFormatter().string(from: recording.date), durationSeconds: recording.duration,
            meetingTitle: recording.meetingTitleDraft, masterFileName: audio.lastPathComponent,
            segmentFileNames: recording.segmentAudioURLs.map(\.lastPathComponent), warnings: recording.finalizationWarnings,
            generatedTitle: recording.generatedTitle, participants: recording.participants,
            calendarAttendees: recording.calendarEvent?.attendeeNames ?? [], associatedApp: recording.associatedApp)
        try await processingPipeline.recordCompletion(completion, audioURL: audio, fallback: fallback)
        try Task.checkCancellation()
        guard appState.processingJob === job, recording.finalizedAudioURL == audio else { throw CancellationError() }
    }

    /// Save participant context after finalization so reopening a recording can
    /// offer meeting names even if later processing was cancelled.
    private func persistMeetingContext(for recording: Recording, job: ProcessingJob) async {
        let participants = PersonName.displayList(recording.participants)
        let attendees = recording.calendarEvent?.attendeeNames ?? []
        guard !participants.isEmpty || !attendees.isEmpty || recording.calendarEvent != nil else { return }
        if let event = recording.calendarEvent, let audio = recording.finalizedAudioURL {
            do { try await RecordingMetadataStore.shared.linkCalendar(event, audioURL: audio, updateTitle: false, updateParticipants: false) }
            catch { Logger.recording.error("Could not persist calendar context: \(error.localizedDescription)") }
        }
        await updateMetadataSidecar(.meetingContext(participants: participants, calendarAttendees: attendees),
                                    for: recording, job: job, describing: "meeting participants")
    }

    /// Snapshot UI-owned values before the actor hop. Missing/corrupt metadata is
    /// a best-effort no-op; a cancelled/superseded job must not publish an error.
    private func updateMetadataSidecar(
        _ update: RecordingMetadataStore.Update, for recording: Recording,
        job: ProcessingJob?, describing what: String
    ) async {
        guard !Task.isCancelled, let job, appState.processingJob === job,
              job.recording === recording, let audioURL = recording.finalizedAudioURL else { return }
        do {
            try await processingPipeline.updateMetadata(update, audioURL: audioURL)
        } catch {
            guard !Task.isCancelled, appState.processingJob === job else { return }
            Logger.recording.error("Failed to persist \(what, privacy: .public) to the recording metadata sidecar")
        }
    }

    private func generatePipelineTitle(for job: ProcessingJob, transcription: String, endpoint: Endpoint) async throws -> TimeInterval? {
        try requireProcessingOwnership(job)
        let recording = job.recording
        let previousTitle = recording.generatedTitle
        let input = ProcessingPipeline.TitleRequest(transcription: transcription, summary: recording.summary,
                                                     language: recording.transcription?.language, endpoint: endpoint)
        let service = aiService
        let output = try await processingPipeline.generateTitle(input, using: { request in
            try await service.generateTitle(transcription: request.transcription, language: request.language, endpoint: request.endpoint)
        }, validateOwnership: { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.requireProcessingOwnership(job)
        })
        try requireProcessingOwnership(job)
        if let title = output.title, recording.generatedTitle == previousTitle, shouldGenerateTitle(for: recording) {
            recording.generatedTitle = title
        }
        return output.duration
    }

    private func publishPipelineMarkdown(for job: ProcessingJob, mode: ProcessingPipeline.MarkdownMode) async throws -> ProcessingPipeline.MarkdownOutput {
        try requireProcessingOwnership(job)
        let recording = job.recording
        let input = ProcessingPipeline.MarkdownRequest(snapshot: .init(recording: recording),
            outputFolder: resolveMarkdownOutputFolder(for: recording), includeTranscript: appSettings.obsidianIncludeTranscript, mode: mode)
        let output = try await processingPipeline.publishMarkdown(input, store: markdownOutputStore,
            savePlan: { [weak self] plan in
                guard let self else { throw CancellationError() }
                try await self.saveMarkdownPlan(plan, for: job)
            }, validateOwnership: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.requireProcessingOwnership(job)
            })
        try requireProcessingOwnership(job)
        return output
    }

    private func persistInsightsSidecar(
        for recording: Recording,
        markdownURL: URL?
    ) async throws {
        guard let job = appState.processingJob, job.recording === recording else { throw CancellationError() }
        try requireProcessingOwnership(job)
        let url = recording.insightsSidecarURL
        let insights = RecordingInsights(
            summary: recording.summary ?? "",
            actionItems: recording.actionItems ?? [],
            tags: recording.tags ?? [],
            sentiment: recording.sentiment ?? "",
            generatedTitle: recording.generatedTitle,
            markdownPath: markdownURL?.path,
            modelProvenance: recording.analysisModelProvenance
        )
        try await processingPipeline.saveAnalysis(insights, to: url, store: insightsStore)
        try requireProcessingOwnership(job)
        guard recording.insightsSidecarURL == url else { throw CancellationError() }
    }

    private func applyInsights(_ insights: RecordingInsights, to recording: Recording) {
        recording.summary = insights.summary
        recording.actionItems = insights.actionItems
        recording.tags = insights.tags
        recording.sentiment = insights.sentiment
        recording.generatedTitle = insights.generatedTitle
        recording.analysisModelProvenance = insights.modelProvenance
    }

    private func resolveMarkdownOutputFolder(for recording: Recording) -> URL {
        if appSettings.obsidianEnabled,
           let obsidianFolder = appSettings.obsidianFolderURL(
            relativePath: recording.obsidianFolderRelativePath ?? appSettings.effectiveObsidianDefaultFolderRelativePath
           ) {
            return obsidianFolder
        }
        return appSettings.effectiveTranscriptionFolderURL
    }

    // MARK: - Queue Persistence

    /// Serializes retention with capture, processing, delivery review, and queue
    /// mutations. Never delete inputs while an async processor is reading them.
    func runRetentionCleanup(category: RetentionCategory, days: Int, folders: [URL]) async throws -> RetentionCleanupResult {
        await refreshReprocessingAttempts()
        guard reprocessingRecoveryReady, reprocessingAttempts.isEmpty, !reprocessingAdmissionBusy else {
            throw ReprocessingError.pendingAttempt
        }
        guard !captureCoordinator.isBusy, appState.isIdle, !appState.showPostRecordingSheet, !postRecordingAction.isBusy,
              !queueEnqueueInProgress, appState.processingJob == nil,
              !recoveryMaintenanceInProgress, !processingCancellationInProgress, !queueMutationInProgress, !reviewingIntegrationDeliveries else {
            throw NSError(domain: "RecordingManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wait for recording and processing to finish, then retry cleanup."])
        }
        recoveryMaintenanceInProgress = true
        defer { recoveryMaintenanceInProgress = false }
        let lifecycle = RecoveryLifecycle(jobs: processingJobStore, deliveries: integrationDeliveryStore)
        let result = try await processingPipeline.cleanupRetention(category: category, days: days,
            folders: folders, lifecycle: lifecycle)
        try await reprocessingStore.purgeCompletedForMissingAudio()
        if category == .transcripts {
            let cutoff = Date().addingTimeInterval(-Double(max(0, days)) * 86_400)
            try await reprocessingStore.purgeCompletedTranscriptHistory(olderThan: cutoff, in: folders)
        }
        await refreshWorkQueue()
        return result
    }

    func deleteRecording(_ audioURL: URL) async throws {
        await refreshReprocessingAttempts()
        guard reprocessingRecoveryReady, !isReprocessing(audioURL), !reprocessingAdmissionBusy else { throw ReprocessingError.pendingAttempt }
        defer { RecordingLibraryChange.notify() }
        guard !captureCoordinator.isBusy, appState.isIdle, !appState.showPostRecordingSheet, !postRecordingAction.isBusy,
              !queueEnqueueInProgress, appState.processingJob == nil,
              !recoveryMaintenanceInProgress, !processingCancellationInProgress, !queueMutationInProgress, !reviewingIntegrationDeliveries else {
            throw NSError(domain: "RecordingManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wait for recording and processing to finish before deleting a recording."])
        }
        recoveryMaintenanceInProgress = true
        defer { recoveryMaintenanceInProgress = false }
        let lifecycle = RecoveryLifecycle(jobs: processingJobStore, deliveries: integrationDeliveryStore)
        do {
            try await processingPipeline.deleteRecordingFiles(audioURL, lifecycle: lifecycle)
            try await reprocessingStore.purgeCompleted(audioURL: audioURL)
        } catch {
            await refreshWorkQueue()
            throw error
        }
        await refreshWorkQueue()
    }

    private static func queueURL(for recording: Recording) -> URL? {
        guard let audioURL = recording.finalizedAudioURL else { return nil }
        return audioURL.deletingPathExtension().appendingPathExtension("queue.json")
    }

    private func saveQueueItem(_ item: QueueItem, for recording: Recording) async throws {
        guard let audio = recording.finalizedAudioURL else {
            throw NSError(domain: "RecordingManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot determine queue file path — recording not finalized."
            ])
        }
        var resolved = item
        resolved.profileID = resolved.profileID ?? appSettings.activeProfile.id
        queueRefreshGeneration += 1
        try await queueScheduleStore.saveItem(resolved, for: audio)
        queueRefreshGeneration += 1
    }

    private var configuredQueueFolders: [URL] {
        [appSettings.recordingFolderURL] + appSettings.profiles.compactMap { profile -> URL? in
            guard let path = profile.overrides.recordingFolderPath,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// Queue files and scheduling are read on their shared actor; generation
    /// checks prevent older refreshes from overwriting newer UI intent.
    func refreshQueuedCount() async { await refreshWorkQueue() }

    func refreshWorkQueue() async {
        await refreshReprocessingAttempts()
        queueRefreshGeneration += 1
        let generation = queueRefreshGeneration
        do {
            let snapshot = try await queueScheduleStore.snapshot(configuredFolders: configuredQueueFolders)
            let discovery = await processingJobStore.discover()
            let batches = try await integrationDeliveryStore.discover()
            guard generation == queueRefreshGeneration else { return }
            pendingQueueItems = snapshot.items.filter {
                $0.audioURL.standardizedFileURL != appState.processingJob?.recording.finalizedAudioURL?.standardizedFileURL
            }
            appState.queuedCount = pendingQueueItems.count
            queuePaused = snapshot.schedule.paused || queueSafetyHold
            recoveryQueueEntries = RecoveryQueueEntry.entries(jobs: discovery.jobs, deliveries: batches,
                queuedIDs: Set(snapshot.items.map { $0.item.id }), activeID: appState.processingJob?.id)
            queueLoadError = discovery.issues.isEmpty ? nil : "Some recovery records could not be read and were left untouched."
        } catch {
            guard generation == queueRefreshGeneration else { return }
            queueLoadError = "Saved queue or delivery records could not be read. Their files were left untouched."
        }
    }

    @discardableResult
    func setQueuePaused(_ paused: Bool, clearSafetyHold: Bool = true) async -> Bool {
        queuePauseGeneration += 1
        let generation = queuePauseGeneration
        queuePauseWriteInProgress = true
        queueRefreshGeneration += 1
        defer {
            if generation == queuePauseGeneration { queuePauseWriteInProgress = false }
            queueRefreshGeneration += 1
        }
        do {
            _ = try await queueScheduleStore.setPaused(paused, revision: generation)
            guard generation == queuePauseGeneration else { return false }
            queuePaused = paused || (queueSafetyHold && !clearSafetyHold)
            if clearSafetyHold { queueSafetyHold = false }
            if paused { drainAllQueued = false }
            return true
        } catch {
            guard generation == queuePauseGeneration else { return false }
            appState.lastError = "Couldn't save the queue setting. Check available storage and try again."
            return false
        }
    }

    func moveQueuedItem(_ audioURL: URL, by offset: Int) async {
        guard !queueMutationInProgress, !recoveryMaintenanceInProgress, !processingCancellationInProgress else { return }
        queueMutationInProgress = true
        queueRefreshGeneration += 1
        do {
            let snapshot = try await queueScheduleStore.move(audioURL, by: offset, configuredFolders: configuredQueueFolders,
                excludingAudioURL: appState.processingJob?.recording.finalizedAudioURL)
            pendingQueueItems = snapshot.items.filter {
                $0.audioURL.standardizedFileURL != appState.processingJob?.recording.finalizedAudioURL?.standardizedFileURL
            }
        } catch { appState.lastError = "Couldn't save the queue order. The previous order is unchanged." }
        queueMutationInProgress = false
        queueRefreshGeneration += 1
        await drainQueueIfNeeded()
    }

    func removeQueuedItem(_ audioURL: URL) async {
        guard !queueMutationInProgress, !recoveryMaintenanceInProgress,
              !processingCancellationInProgress,
              audioURL.standardizedFileURL != appState.processingJob?.recording.finalizedAudioURL?.standardizedFileURL else { return }
        queueMutationInProgress = true
        queueRefreshGeneration += 1
        do {
            try await queueScheduleStore.removeQueuedItem(at: audioURL,
                lifecycle: RecoveryLifecycle(jobs: processingJobStore, deliveries: integrationDeliveryStore))
            await refreshWorkQueue()
        } catch {
            queueSafetyHold = true
            queuePaused = true
            _ = await setQueuePaused(true, clearSafetyHold: false)
            queueSafetyHold = true
            queuePaused = true
            appState.lastError = "Couldn't remove the queued item. Processing is paused for this session; check storage and try again."
        }
        queueMutationInProgress = false
        queueRefreshGeneration += 1
        await drainQueueIfNeeded()
    }

    private func dismissRecoveryRecord(id: UUID) async throws {
        try await RecoveryLifecycle(jobs: processingJobStore, deliveries: integrationDeliveryStore).dismiss(id: id)
    }

    func dismissRecoveryItem(_ id: UUID) async {
        guard !queueMutationInProgress, !recoveryMaintenanceInProgress, !processingCancellationInProgress,
              !reviewingIntegrationDeliveries, appState.processingJob == nil else { return }
        queueMutationInProgress = true
        defer { queueMutationInProgress = false }
        do {
            try await dismissRecoveryRecord(id: id)
            await refreshWorkQueue()
        } catch { appState.lastError = "Couldn't dismiss this recovery item. Check storage and try again." }
    }

    func resumeRecoveryItem(_ id: UUID) async {
        guard appState.processingJob == nil, !queueMutationInProgress, !recoveryMaintenanceInProgress,
              !processingCancellationInProgress, !reviewingIntegrationDeliveries else { return }
        queueMutationInProgress = true
        defer { queueMutationInProgress = false }
        do {
            guard let record = try await processingJobStore.load(id: id),
                  record.dismissedFromQueue != true, record.status != .completed,
                  !record.checkpoint.hasCompleted(.markdownGenerated) else { return }
            guard let recording = try await recordingForRecovery(record) else {
                appState.lastError = "The recording is unavailable. Reconnect its storage, then try Resume again."
                return
            }
            guard appState.processingJob == nil else { return }
            try Task.checkCancellation()
            let saved = record
            let request = record.request
            queueMutationInProgress = false
            launchJob(recording: recording, existingRecord: saved) { job in
                if saved.checkpoint.hasCompleted(.analyzed) {
                    await self.resumeExport(job: job)
                } else {
                    await self.processRecording(job: job, transcribe: request.transcribe,
                        summary: request.summary, actionItems: request.actionItems, tags: request.tags,
                        stopBeforeIntegrations: true)
                }
            }
        } catch { appState.lastError = "Couldn't load this recovery item. Its saved files were left untouched." }
    }

    var canPerformLibraryWork: Bool {
        !captureCoordinator.isBusy && appState.recordingState == .idle && !appState.showPostRecordingSheet && appState.processingJob == nil
            && !queueMutationInProgress && !recoveryMaintenanceInProgress && !processingCancellationInProgress
            && !reviewingIntegrationDeliveries
    }

    /// A library row is a snapshot. Revalidate its durable identity and current
    /// stage before forwarding an explicit button click to existing safe actions.
    func performLibraryWork(_ item: LibraryWorkItem) async throws {
        guard canPerformLibraryWork else { throw LibraryWorkNavigation.Failure.busy }
        // Reserve queue mutations while resolving, so a concurrent dismissal
        // cannot be superseded by this older click. Existing actions acquire their
        // own guard synchronously after the reservation is handed off below.
        queueMutationInProgress = true
        let destination: LibraryWorkNavigation.Destination
        do {
            destination = try await LibraryWorkNavigation.resolve(item, jobs: processingJobStore, deliveries: integrationDeliveryStore)
            try Task.checkCancellation()
        } catch {
            queueMutationInProgress = false
            throw error
        }
        queueMutationInProgress = false
        guard canPerformLibraryWork else { throw LibraryWorkNavigation.Failure.busy }
        switch destination {
        case .queue(let id, let audio):
            await drainQueueIfNeeded(preferredAudioURL: audio, expectedID: id)
            guard appState.processingJob?.id == id else {
                throw NSError(domain: "LibraryWork", code: 1, userInfo: [NSLocalizedDescriptionKey: queueLoadError ?? "This queued recording could not be started. Refresh the queue and try again."])
            }
        case .processing(let id):
            await resumeRecoveryItem(id)
            guard appState.processingJob?.id == id else {
                throw NSError(domain: "LibraryWork", code: 2, userInfo: [NSLocalizedDescriptionKey: appState.lastError ?? "This recovery item could not be resumed. Refresh the library and try again."])
            }
        case .delivery(let id, let audio):
            await reviewIntegrationDeliveries(for: audio, batchID: id)
        case .capture(let id):
            guard await recoverInterruptedSessions(only: id) else {
                throw NSError(domain: "LibraryWork", code: 3, userInfo: [NSLocalizedDescriptionKey: "This interrupted recording could not be recovered. Reconnect its storage and try again."])
            }
        }
        await refreshWorkQueue()
        RecordingLibraryChange.notify()
    }

    private func recoveryInputRequest(for recording: Recording, mode: ProcessingPipeline.RecoveryInputMode) -> ProcessingPipeline.RecoveryInputRequest {
        .init(mode: mode, transcriptURL: recording.transcriptURL ?? Self.transcriptURL(for: recording),
              richTranscriptURL: recording.transcriptSidecarURL, transcription: recording.transcription,
              richTranscript: recording.richTranscript)
    }

    private func requireRecoveryInputPaths(_ input: ProcessingPipeline.RecoveryInputRequest, recording: Recording) throws {
        try input.validatePaths(transcriptURL: recording.transcriptURL ?? Self.transcriptURL(for: recording),
                                richTranscriptURL: recording.transcriptSidecarURL)
    }

    /// Derives the transcript JSON path from the finalized audio URL.
    private static func transcriptURL(for recording: Recording) -> URL? {
        guard let audioURL = recording.finalizedAudioURL else { return nil }
        return audioURL.deletingPathExtension().appendingPathExtension("transcript.json")
    }

    /// Saves only for the active owner; the actor verifies bytes before the
    /// caller may advance the job checkpoint and remove its legacy queue marker.
    private func saveTranscript(_ result: TranscriptionResult, for job: ProcessingJob) async throws {
        try Task.checkCancellation()
        guard appState.processingJob === job else { throw CancellationError() }
        let recording = job.recording
        let url = Self.transcriptURL(for: recording)
        try await processingPipeline.saveTranscript(result, to: url)
        try Task.checkCancellation()
        guard appState.processingJob === job, Self.transcriptURL(for: recording) == url else {
            throw CancellationError()
        }
        recording.transcriptURL = url
    }

    /// UI objects stay on MainActor. Only a result for the unchanged URL may
    /// update the recording's sidecar reference after the actor read completes.
    private func loadSavedTranscript(for recording: Recording) async -> TranscriptionResult? {
        let url = recording.transcriptURL ?? Self.transcriptURL(for: recording)
        guard let result = try? await processingPipeline.loadTranscript(from: url),
              !Task.isCancelled,
              (recording.transcriptURL ?? Self.transcriptURL(for: recording)) == url else { return nil }
        recording.transcriptURL = url
        return result
    }

    /// Growth loop: when the user names a diarized speaker, enroll that speaker's
    /// stored voiceprint into the library so future meetings recognize them.
    /// Resolves embeddings from memory or the saved `.transcript.json`. Best-effort;
    /// returns the library person id, or nil when no embedding exists for the
    /// speaker (a pre-embedding recording / extraction miss) or the name is blank.
    func enrollVoiceprintOnRename(recording: Recording, speakerId: String, name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let embeddings = await speakerEmbeddings(for: recording)
        guard !Task.isCancelled else { return nil }
        guard let embedding = embeddings?[speakerId], !embedding.isEmpty else { return nil }
        let id = await voiceLibraryStore.upsert(
            name: trimmed,
            voiceprint: Voiceprint(embedding: embedding, model: "fluidaudio-wespeaker-256", capturedAt: Date()))
        Logger.transcription.info("Enrolled voiceprint for a manually-named speaker")
        await suggestCompany(forPersonId: id, name: trimmed, recording: recording)
        return id.isEmpty ? nil : id
    }

    /// Fill-only company suggestion: if the enrolled name matches a calendar attendee
    /// with a corporate email domain, seed the person's company (never overwrites).
    private func suggestCompany(forPersonId personId: String, name: String, recording: Recording) async {
        guard !personId.isEmpty else { return }
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty,
              let attendee = recording.calendarEvent?.attendees
                  .first(where: { PersonName.display($0.name).lowercased() == key }),
              let company = CompanyName.fromDomain(attendee.emailDomain) else { return }
        await voiceLibraryStore.suggestCompanyIfEmpty(id: personId, to: company)
    }

    /// Speaker ids with a non-empty voice embedding available right now (from the
    /// in-memory transcription or the persisted `.transcript.json` sidecar) — i.e.
    /// the speakers that `enrollVoiceprintOnRename` could enroll.
    func embeddedSpeakerIds(for recording: Recording) async -> Set<String> {
        guard let embeddings = await speakerEmbeddings(for: recording), !Task.isCancelled else { return [] }
        return Set(embeddings.filter { !$0.value.isEmpty }.keys)
    }

    private func speakerEmbeddings(for recording: Recording) async -> [String: [Float]]? {
        if let embeddings = recording.transcription?.speakerEmbeddings { return embeddings }
        let saved = await loadSavedTranscript(for: recording)
        guard !Task.isCancelled else { return nil }
        return recording.transcription?.speakerEmbeddings ?? saved?.speakerEmbeddings
    }

    private func prepareIntegrationDeliveries(job: ProcessingJob, markdownURL: URL?) async throws -> IntegrationDeliveryBatch {
        try requireProcessingOwnership(job)
        let succeeded = job.observesProcessingFromStart && !appState.processingSteps.contains {
            if case .failed = $0.status { return true }
            return false
        }
        let input = ProcessingPipeline.DeliveryPreparation(jobID: job.id,
            recording: RecordingSnapshot(recording: job.recording), configuration: appSettings.integrations,
            markdownURL: markdownURL, requireTranscript: job.persistedRecord?.request.transcribe == true,
            processingSucceededBeforeDeliveryAt: succeeded ? Date() : nil)
        let batch = try await processingPipeline.prepareDeliveries(input, store: integrationDeliveryStore,
            service: integrationDispatchService, validateOwnership: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.requireProcessingOwnership(job)
            })
        try requireProcessingOwnership(job)
        return batch
    }

    private func dispatchTrackedIntegrations(job: ProcessingJob, markdownURL: URL?, stopBeforeIntegrations: Bool = false) async -> Bool {
        let batch: IntegrationDeliveryBatch
        do {
            batch = try await prepareIntegrationDeliveries(job: job, markdownURL: markdownURL)
        } catch {
            guard !Task.isCancelled, appState.processingJob === job else { return false }
            appState.lastError = error.localizedDescription
            await markPersistedJobFailed(.integrations, job: job)
            return false
        }
        do {
            let result = try await processingPipeline.finishDeliveryHandoff(batch, stopBeforeIntegrations: stopBeforeIntegrations,
                run: { [weak self] saved in
                    guard let self else { throw CancellationError() }
                    return try await self.runIntegrationDeliveries(batch: saved, job: job)
                }, park: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.parkDeliveryHandoff(job)
                }, checkpoint: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.checkpointDeliveryHandoff(job)
                }, validateOwnership: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.requireProcessingOwnership(job)
                })
            try requireProcessingOwnership(job)
            if result.held {
                appState.durabilityNoticeIsWarning = false
                appState.durabilityNotice = "Recovered processing through Markdown export. Integrations were not sent automatically."
                return true
            }
            for entry in result.batch.deliveries {
                guard !appState.processingSteps.contains(where: { $0.name == "Send: \(entry.destination.displayName)" }) else { continue }
                appState.processingSteps.append(ProcessingStep(name: "Send: \(entry.destination.displayName)",
                    status: entry.isComplete ? .completed : .failed(entry.statusDescription)))
            }
            guard result.batch.isComplete else {
                await markPersistedJobFailed(.integrations, job: job)
                try requireProcessingOwnership(job)
                appState.lastError = "Some integrations need attention. Open Integrations in History to review or retry individual sends."
                return false
            }
            job.successfulCompletion = result.completion
            return true
        } catch {
            guard !Task.isCancelled, appState.processingJob === job else { return false }
            if stopBeforeIntegrations {
                appState.lastError = "Markdown was saved, but its completion checkpoint could not be updated."
            } else {
                appState.lastError = error.localizedDescription
                await markPersistedJobFailed(.integrations, job: job)
            }
            return false
        }
    }

    private func parkDeliveryHandoff(_ job: ProcessingJob) async throws {
        try requireProcessingOwnership(job)
        try await markMarkdownBoundaryReached(job)
        try requireProcessingOwnership(job)
        try await completeLegacyQueueCheckpoint(for: job)
    }

    private func checkpointDeliveryHandoff(_ job: ProcessingJob) async throws {
        try requireProcessingOwnership(job)
        try await persistCheckpoint(.integrationsDispatched, for: job)
        try requireProcessingOwnership(job)
    }

    private func runIntegrationDeliveries(
        batch: IntegrationDeliveryBatch, job: ProcessingJob,
        destinations: Set<IntegrationDestination>? = nil,
        allowUncertainRetry: Bool = false, acceptConfigurationChange: Bool = false
    ) async throws -> IntegrationDeliveryBatch {
        try requireProcessingOwnership(job)
        let input = ProcessingPipeline.DeliveryRun(id: batch.id,
            configurationDigests: try IntegrationDeliveryBatch.configurationDigests(appSettings.integrations),
            destinations: destinations, allowUncertainRetry: allowUncertainRetry,
            acceptConfigurationChange: acceptConfigurationChange)
        let service = integrationDispatchService
        let settings = appSettings
        return try await processingPipeline.runDeliveries(input, coordinator: integrationDeliveryCoordinator,
            send: { saved, delivery in
                // Credentials/configuration are read per attempt. The dispatcher
                // still compares the actual destination with its frozen digest.
                let config = await MainActor.run { settings.integrations }
                return await service.send(batch: saved, delivery: delivery, config: config)
            }, onEvent: { [weak self] event in
                await self?.applyDeliveryEvent(event, job: job)
            }, validateOwnership: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.requireProcessingOwnership(job)
            })
    }

    private func applyDeliveryEvent(_ event: ProcessingPipeline.DeliveryEvent, job: ProcessingJob) {
        guard !Task.isCancelled, appState.processingJob === job else { return }
        switch event {
        case .started(let entry):
            appState.processingSteps.append(ProcessingStep(name: "Send: \(entry.destination.displayName)", status: .inProgress))
        case .finished(let result):
            guard let index = appState.processingSteps.lastIndex(where: { $0.name == "Send: \(result.destination.displayName)" }) else { return }
            switch result.status {
            case .success, .skipped: appState.processingSteps[index].status = .completed
            case .failed: appState.processingSteps[index].status = .failed("Delivery unconfirmed. Review Integrations in History before retrying.")
            }
        }
    }

    /// History exposes destination-level retry; this route uses the saved delivery
    /// snapshot directly and never calls transcription, AI, or Markdown generation.
    func reviewIntegrationDeliveries(for audioURL: URL, batchID: UUID? = nil) async {
        guard appState.processingJob == nil, !reviewingIntegrationDeliveries,
              !queueMutationInProgress, !recoveryMaintenanceInProgress, !processingCancellationInProgress else { return }
        reviewingIntegrationDeliveries = true
        defer { reviewingIntegrationDeliveries = false }
        do {
            let loadedBatch = try await integrationBatchForReview(audioURL: audioURL, batchID: batchID)
            try Task.checkCancellation()
            guard let batch = loadedBatch else {
                let alert = NSAlert()
                alert.messageText = "No saved integration deliveries"
                alert.informativeText = "This recording has no tracked sends. Older app versions did not record delivery outcomes, so dBrief cannot safely retry them here."
                alert.addButton(withTitle: "Close")
                alert.runModal()
                return
            }
            let remaining = batch.deliveries.filter { !$0.isComplete }
            let alert = NSAlert()
            alert.messageText = "Integration deliveries"
            alert.informativeText = batch.deliveries.isEmpty
                ? "No integrations were enabled for this processing job."
                : batch.deliveries.map { "\($0.destination.displayName): \($0.statusDescription)" }.joined(separator: "\n\n")
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
            if !remaining.isEmpty {
                picker.addItems(withTitles: remaining.map { $0.destination.displayName })
                picker.setAccessibilityLabel("Integration to retry")
                alert.accessoryView = picker
                alert.addButton(withTitle: "Send Selected")
            }
            alert.addButton(withTitle: "Close")
            guard alert.runModal() == .alertFirstButtonReturn, !remaining.isEmpty else { return }
            let selected = remaining[picker.indexOfSelectedItem]
            let currentDigest = try IntegrationDeliveryBatch.configurationDigests(appSettings.integrations)[selected.destination]
            guard let currentDigest else {
                appState.lastError = "Enable \(selected.destination.displayName) in Settings before retrying."
                return
            }
            let configurationChanged = currentDigest != selected.configurationDigest
            if selected.needsDuplicateConfirmation || configurationChanged {
                let warning = NSAlert()
                warning.alertStyle = .warning
                warning.messageText = "Retry \(selected.destination.displayName)?"
                var explanations: [String] = []
                if selected.needsDuplicateConfirmation {
                    explanations.append("The previous attempt may already have created a note, reminders, or a webhook event. Check the destination first. Retrying may create duplicates. Webhook deduplication depends on the receiver honoring the idempotency key.")
                }
                if configurationChanged {
                    explanations.append("The integration settings have changed. Using current settings may send this saved content to a different account, folder, or URL, or include different selected fields.")
                }
                warning.informativeText = explanations.joined(separator: "\n\n")
                warning.addButton(withTitle: "Cancel")
                warning.addButton(withTitle: configurationChanged ? "Send with Current Settings" : "Retry Anyway")
                guard warning.runModal() == .alertSecondButtonReturn else { return }
            }
            guard appState.processingJob == nil else {
                appState.lastError = "Wait for the active processing job to finish before retrying integrations."
                return
            }
            let recording = Recording(id: batch.recordingID, date: batch.bundle.createdAt,
                                      fileURL: audioURL, duration: batch.bundle.durationSeconds,
                                      meetingTitleDraft: batch.bundle.title, finalizedAudioURL: audioURL)
            recording.generatedTitle = batch.bundle.title
            recording.summary = batch.bundle.summary
            recording.actionItems = batch.bundle.actionItems
            recording.tags = batch.bundle.tags
            recording.sentiment = batch.bundle.sentiment
            appState.processingSteps = []
            let job = launchJob(id: batch.id, recording: recording) { retryJob in
                do {
                    let result = try await self.runIntegrationDeliveries(
                        batch: batch, job: retryJob, destinations: [selected.destination],
                        allowUncertainRetry: selected.needsDuplicateConfirmation,
                        acceptConfigurationChange: configurationChanged)
                    guard !Task.isCancelled, self.appState.processingJob === retryJob else { return }
                    if let entry = result.deliveries.first(where: { $0.id == selected.id }),
                       !self.appState.processingSteps.contains(where: { $0.name == "Send: \(entry.destination.displayName)" }) {
                        self.appState.processingSteps.append(ProcessingStep(
                            name: "Send: \(entry.destination.displayName)",
                            status: entry.isComplete ? .completed : .failed(entry.statusDescription)))
                    }
                    if result.isComplete {
                        let savedRecord = try await self.processingJobStore.load(id: batch.id)
                        guard !Task.isCancelled, self.appState.processingJob === retryJob else { return }
                        if var record = savedRecord {
                            _ = record.markCompleted(.integrationsDispatched, at: Date())
                            record.markFullyCompleted(at: result.successfulWorkflowCompletion?.completedAt ?? Date(),
                                                      successful: result.successfulWorkflowCompletion != nil)
                            try await self.processingJobStore.save(record)
                        }
                        guard !Task.isCancelled, self.appState.processingJob === retryJob else { return }
                        if let completion = result.successfulWorkflowCompletion {
                            try await self.persistProcessingCompletion(completion, for: retryJob)
                            guard !Task.isCancelled, self.appState.processingJob === retryJob else { return }
                        }
                    }
                    if !result.isComplete {
                        self.appState.lastError = "Some deliveries still need attention. Open Integrations in History to review them."
                    }
                } catch {
                    guard !Task.isCancelled, self.appState.processingJob === retryJob else { return }
                    self.appState.lastError = error.localizedDescription
                }
                await self.finishJob(retryJob, completed: false)
            }
            await job.task?.value
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func integrationBatchForReview(audioURL: URL, batchID: UUID? = nil) async throws -> IntegrationDeliveryBatch? {
        if let batchID {
            if let saved = try await integrationDeliveryStore.load(id: batchID) { return saved }
        } else if let saved = try await integrationDeliveryStore.latest(forAudioURL: audioURL) { return saved }
        let discovery = await processingJobStore.discover()
        guard let record = discovery.jobs.filter({
            $0.source.finalizedAudioPath == audioURL.path && $0.checkpoint.hasCompleted(.markdownGenerated)
                && (batchID == nil || $0.id == batchID)
        }).max(by: { $0.createdAt < $1.createdAt }),
              let recording = try await recordingForRecovery(record) else { return nil }
        recording.transcription = await loadSavedTranscript(for: recording)
        try Task.checkCancellation()
        if record.request.transcribe, recording.transcription == nil { throw TranscriptStoreError.noSidecarURL }
        let insights = try await insightsStore.load(for: recording)
        if let insights { applyInsights(insights, to: recording) }
        if record.analysisOutputSaved == true, insights == nil { throw InsightsStoreError.noSidecarURL }
        let markdownURL = record.markdownExport?.destination
            ?? insights?.markdownPath.map { URL(fileURLWithPath: $0) }
        recording.generatedTitle = record.markdownExport?.generatedTitle ?? recording.generatedTitle
        var proposed = try await integrationDispatchService.prepareBatch(
            jobID: record.id, recording: RecordingSnapshot(recording: recording), config: appSettings.integrations, generatedMarkdownURL: markdownURL,
            requireTranscript: record.request.transcribe)
        // Pre-5D jobs cannot prove whether a remote send occurred. Never assume
        // they are unsent, even when their processing checkpoint says otherwise.
        for index in proposed.deliveries.indices { proposed.deliveries[index].status = .uncertain }
        try Task.checkCancellation()
        return try await integrationDeliveryStore.createIfAbsent(proposed)
    }


}
