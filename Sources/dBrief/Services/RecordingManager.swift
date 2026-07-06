
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
    private let appState: AppState
    private let appSettings: AppSettings
    private let audioCaptureManager = AudioCaptureManager()
    private let transcriptionService = TranscriptionService()
    private let localTranscriptionService = LocalTranscriptionService()
    /// Real-time, in-process Apple Speech transcription during recording (preview only).
    private var liveTranscriptionService: LiveTranscriptionService?
    /// One supervised helper process backs both local-ML proxies, so they share
    /// the GPU-serializing orchestrator inside dBriefMLHost.
    private let mlHost = MLHostConnection(
        binaryURL: MLHostLocator.binaryURL(),
        supportBase: MLHostLocator.supportBase())
    private let localAIPluginService: LocalAIPluginService
    private let parakeetService: ParakeetTranscriptionService
    /// Exposed for TranscriptChatService — read-only reference; access serialized by the helper's AsyncMutex.
    var localPlugin: LocalAIPluginService { localAIPluginService }
    var miniPlayer: FloatingMiniPlayerController?
    private var processingTask: Task<Void, Never>?
    /// Auto-clears the transient `appState.recordingStatusNote` a few seconds after a switch.
    private var statusNoteClearTask: Task<Void, Never>?
    /// Observable per-model download state, read by the Settings download buttons.
    var modelDownloads: [LocalModelKind: ModelDownloadPhase] = [:]
    private var downloadTasks: [LocalModelKind: Task<Void, Never>] = [:]
    private var downloadObservers: [LocalModelKind: Task<Void, Never>] = [:]
    private let aiService = AIService()
    private let localCLIService = LocalCLIService()
    private let markdownGenerator = MarkdownGenerator()
    private let integrationDispatchService = IntegrationDispatchService()
    private let recordingFinalizer = RecordingFinalizer()
    private let transcriptStore: TranscriptStore
    private let insightsStore: InsightsStore
    private let voiceLibraryStore: VoiceLibraryStore
    private let modelPerformanceStore: ModelPerformanceStore
    private let richTranscriptBuilder = RichTranscriptBuilder()
    private let youtubeDownloadService = YouTubeDownloadService()
    private let calendarService = CalendarService()
    private let microsoftAuthService: MicrosoftAuthService
    private let outlookCalendarService: OutlookCalendarService

    // Memory requirements for local models (bytes)
    private enum MemoryThreshold {
        static let gemma4_e4b: Int64 = 4_800_000_000  // ~4.8 GB
    }

    init(appState: AppState, appSettings: AppSettings, transcriptStore: TranscriptStore, insightsStore: InsightsStore, voiceLibraryStore: VoiceLibraryStore, modelPerformanceStore: ModelPerformanceStore, microsoftAuthService: MicrosoftAuthService) {
        self.appState = appState
        self.appSettings = appSettings
        self.transcriptStore = transcriptStore
        self.insightsStore = insightsStore
        self.voiceLibraryStore = voiceLibraryStore
        self.modelPerformanceStore = modelPerformanceStore
        self.microsoftAuthService = microsoftAuthService
        self.outlookCalendarService = OutlookCalendarService(authService: microsoftAuthService)
        self.localAIPluginService = LocalAIPluginService(connection: mlHost)
        self.parakeetService = ParakeetTranscriptionService(connection: mlHost)
        // Surface automatic mid-recording device/AEC switches to the user.
        self.audioCaptureManager.statusNoteHandler = { [weak self] note in
            self?.showRecordingStatusNote(note)
        }
        // Mirror the capture manager's meter into AppState from its own 10 Hz
        // timer — one source of truth, no second polling loop. Peak drives the
        // waveform at full rate; duration only shows whole seconds, so push it
        // just once per second to avoid needless SwiftUI invalidations.
        self.audioCaptureManager.stateTickHandler = { [weak self] duration, peak in
            guard let self else { return }
            self.appState.peakLevel = peak
            if Int(duration) != Int(self.appState.recordingDuration) {
                self.appState.recordingDuration = duration
            }
        }
    }

    /// Briefly shows a status note (e.g. "Switched to MacBook Microphone") during
    /// recording, auto-clearing after a few seconds.
    private func showRecordingStatusNote(_ note: String) {
        appState.recordingStatusNote = note
        Logger.recording.info("Recording status note: \(note, privacy: .public)")
        statusNoteClearTask?.cancel()
        statusNoteClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.appState.recordingStatusNote = nil
        }
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
        await audioCaptureManager.checkPermissions()
    }

    var hasSystemAudioPermission: Bool { audioCaptureManager.hasSystemAudioPermission }
    var hasMicrophonePermission: Bool { audioCaptureManager.hasMicrophonePermission }

    func startRecording(associatedApp: String? = nil) async throws {
        // A recording takes priority over any in-flight model download: cancel
        // active downloads so the recording pipeline is the sole consumer of the
        // services' state streams (and the GPU mutex is free).
        cancelAllActiveDownloads()

        let baseURL = Self.generateRawCaptureBaseURL()

        let recording = Recording(
            fileURL: baseURL,
            associatedApp: associatedApp,
            meetingTitleDraft: defaultMeetingTitle(from: associatedApp)
        )
        appState.currentRecording = recording

        // The calendar lookup happens at stopRecording (not here): only once recording stops
        // is the true span [start, start+duration] known, which the span-aware CalendarMatcher
        // needs to rank events that overlap the recording.

        // Create the live audio streams before the capture taps install so the
        // tap handlers capture the sinks (no-op unless the feature is enabled).
        let liveStreams = appSettings.liveTranscriptionEnabled
            ? audioCaptureManager.makeLiveAudioStreams()
            : nil

        // Echo cancellation only helps when sound from the speakers bleeds into the
        // mic. With earphones/headphones (or any non-built-in output) there's no
        // echo path, and Voice Processing would needlessly duck output + apply AGC,
        // making the audio the user hears much quieter. The offline (mixed-mode)
        // sidechain duck is an all-or-nothing ffmpeg filter, so freeze its decision
        // at the start-time route. The live capture path receives the RAW setting and
        // re-gates on the route dynamically (it can toggle VPIO mid-recording).
        let echoCancellationActive = appSettings.acousticEchoCancellation
            && AudioOutputRoute.currentOutputHasEchoPath()
        recording.echoSuppressionApplied = echoCancellationActive
        if appSettings.acousticEchoCancellation && !echoCancellationActive {
            Logger.recording.info("Echo cancellation auto-disabled: output route has no speaker→mic echo path (headphones/external)")
        }

        try await audioCaptureManager.startRecording(
            to: baseURL,
            inputDeviceUID: appSettings.audioInputDeviceUID,
            acousticEchoCancellationEnabled: appSettings.acousticEchoCancellation
        )
        appState.recordingState = .recording

        // Warm the local Whisper model while the user records, so the model
        // load+prewarm cost hides behind the (typically minutes-long) recording
        // instead of being paid at transcription time. Fire-and-forget; the
        // helper reuses this warm model when transcription starts. Only local
        // Whisper benefits — other engines no-op via the engine guard.
        if appSettings.effectiveTranscriptionEngine == .localWhisper {
            let cfg = appSettings.whisperRuntimeConfig
            Task { await localAIPluginService.prewarmWhisper(config: cfg, refresh: false) }
        }

        if appSettings.showMiniRecordingView {
            miniPlayer?.show()
        }

        if let liveStreams {
            startLiveTranscription(streams: liveStreams)
        }
        // Duration/peak now flow from AudioCaptureManager.stateTickHandler
        // (wired in init) — no separate polling loop.
    }

    private func startLiveTranscription(streams: (mic: AsyncStream<LiveAudioBuffer>, system: AsyncStream<LiveAudioBuffer>)) {
        appState.liveTranscriptSegments = []
        appState.liveVolatileMic = ""
        appState.liveVolatileSystem = ""
        appState.liveStatusMessage = ""
        appState.isLiveTranscribing = true

        // Only drive channels that actually have an audio source.
        let micStream = audioCaptureManager.hasMicrophonePermission ? streams.mic : nil
        let systemStream = audioCaptureManager.hasSystemAudioPermission ? streams.system : nil

        let service = LiveTranscriptionService()
        liveTranscriptionService = service
        let language = appSettings.effectiveTranscriptionLanguage
        let micLabel = LiveTranscriptionService.Channel.mic.rawValue

        Task {
            await service.start(
                mic: micStream,
                system: systemStream,
                language: language,
                onFinalized: { [weak self] segments in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // First real output clears any "Preparing language…" status.
                        self.appState.liveStatusMessage = ""
                        self.appState.liveTranscriptSegments = LiveSegmentMerge.insert(segments, into: self.appState.liveTranscriptSegments)
                    }
                },
                onVolatile: { [weak self] speaker, text in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if !text.isEmpty { self.appState.liveStatusMessage = "" }
                        if speaker == micLabel { self.appState.liveVolatileMic = text }
                        else { self.appState.liveVolatileSystem = text }
                    }
                },
                onStatus: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.appState.liveStatusMessage = message
                    }
                }
            )
        }
    }

    private func stopLiveTranscription() {
        guard let service = liveTranscriptionService else { return }
        liveTranscriptionService = nil
        appState.isLiveTranscribing = false
        appState.liveVolatileMic = ""
        appState.liveVolatileSystem = ""
        appState.liveStatusMessage = ""
        Task { await service.stop() }
    }

    func stopRecording() async {
        await audioCaptureManager.stopRecording()
        stopLiveTranscription()
        statusNoteClearTask?.cancel()
        appState.recordingStatusNote = nil

        if let recording = appState.currentRecording {
            // Capture track URLs written by the audio pipeline.
            let tracks = audioCaptureManager.trackURLs
            recording.capturedTracks = tracks
            recording.finalizedAudioURL = nil
            recording.segmentAudioURLs = []
            recording.metadataURL = nil
            recording.finalizationWarnings = []

            // File size: the M4A master doesn't exist until finalization, and
            // `recording.fileURL` is an extension-less scratch base that's never
            // written to disk — so sum the per-track CAF files that do exist.
            recording.fileSize = Self.totalTrackFileSize(tracks)

            // Duration: probe the captured audio so the value is authoritative
            // rather than relying on the live-update timer having fired (it can
            // be starved while the menu-bar popover holds the run loop). Fall
            // back to the timer's last value if probing fails.
            var probedDuration: Double = 0
            if let probeURL = tracks?.micURL ?? tracks?.systemURL {
                probedDuration = await durationSeconds(for: probeURL)
            }
            recording.duration = probedDuration > 0 ? probedDuration : audioCaptureManager.duration

            if recording.meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recording.meetingTitleDraft = defaultMeetingTitle(from: recording.associatedApp)
            }

            // Now that the true recording span is known, find matching calendar events.
            // Detached so the post-recording sheet appears immediately; the ranked
            // candidates + best match populate reactively via @Observable. The handle is
            // stored so the processing pipeline can await it before reading calendarEvent.
            if appSettings.effectiveCalendarSource != .disabled {
                recording.calendarLookupTask = Task { [weak self, weak recording] in
                    guard let self, let recording else { return }
                    await self.lookupCalendarCandidates(for: recording)
                }
            }
        }

        appState.recordingState = .idle
        appState.showPostRecordingSheet = true
        miniPlayer?.dismiss()
    }

    /// Looks up calendar events matching the finished recording's true span and publishes the
    /// ranked candidates + best match. The post-recording sheet observes both to drive the
    /// override picker and pre-fill the title/participants. Never clobbers a `calendarEvent`
    /// the user already picked.
    private func lookupCalendarCandidates(for recording: Recording) async {
        let start = recording.date
        let end = start.addingTimeInterval(recording.duration)
        let candidates: [CalendarEvent]
        switch appSettings.effectiveCalendarSource {
        case .iCal:
            candidates = await calendarService.findCandidates(recordingStart: start, recordingEnd: end)
        case .outlook:
            candidates = await outlookCalendarService.findCandidates(recordingStart: start, recordingEnd: end)
        case .disabled:
            candidates = []
        }
        recording.calendarCandidates = candidates
        if recording.calendarEvent == nil {
            recording.calendarEvent = candidates.first
        }
    }

    func pauseRecording() {
        audioCaptureManager.pauseRecording()
        appState.recordingState = .paused
    }

    func resumeRecording() throws {
        try audioCaptureManager.resumeRecording()
        appState.recordingState = .recording
    }

    /// Switch the microphone input device while recording (manual hot-swap). Persists
    /// the selection and re-points the live mic engine at the new device, keeping the
    /// in-progress mic track continuous.
    func switchInputDevice(to uid: String?) {
        appSettings.audioInputDeviceUID = uid ?? ""
        do {
            try audioCaptureManager.switchMicrophoneDevice(to: uid)
        } catch {
            appState.lastError = "Couldn't switch microphone: \(error.localizedDescription)"
        }
    }

    func processRecording(
        transcribe: Bool,
        summary: Bool,
        actionItems: Bool,
        tags: Bool
    ) async {
        guard appState.recordingState != .processing else { return }
        guard let recording = appState.currentRecording else { return }
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
        appState.recordingState = .processing
        appState.showPostRecordingSheet = false
        appState.preflightWarning = nil
        appState.processingSteps = []
        appState.liveTranscriptSegments = []
        appState.liveVolatileMic = ""
        appState.liveVolatileSystem = ""
        appState.liveStatusMessage = ""
        appState.isLiveTranscribing = false
        appState.liveInferenceText = nil

        // Make sure the calendar lookup started at stop has finished before the pipeline reads
        // calendarEvent for title/participants/AI context — a fast user can otherwise click
        // Process before the (network) Outlook lookup resolves. Completed/absent task → no-op.
        // State is already .processing above, so this suspension can't re-enter processRecording.
        await recording.calendarLookupTask?.value

        // Measured transcription-side performance for this session. Carried into
        // runAnalysisAndExport (which adds the AI-side metrics) and recorded at the end.
        var perfTranscriptionModel: String?
        var perfTranscriptionTime: TimeInterval?
        var perfInferenceTime: TimeInterval?
        var perfDiarizationTime: TimeInterval?
        var perfSpellCorrectionTime: TimeInterval?
        var perfFinalizationTime: TimeInterval?
        var perfAudioDuration: TimeInterval?

        let finalizationStepIndex = appState.processingSteps.count
        appState.processingSteps.append(ProcessingStep(name: "Finalizing audio", status: .inProgress))
        do {
            let finalizeStart = Date()
            try await ensureRecordingFinalized(recording: recording)
            perfFinalizationTime = Date().timeIntervalSince(finalizeStart)
            appState.processingSteps[finalizationStepIndex].status = .completed
            if !recording.finalizationWarnings.isEmpty {
                appState.processingSteps.append(
                    ProcessingStep(
                        name: "Audio finalization warnings",
                        status: .failed(recording.finalizationWarnings.joined(separator: "\n"))
                    )
                )
            }
        } catch {
            appState.processingSteps[finalizationStepIndex].status = .failed(error.localizedDescription)
            appState.recordingState = .idle
            appState.showPostRecordingSheet = true
            return
        }

        // Warm the Apple Intelligence model during transcription so the AI step starts
        // without first-call load latency. Fire-and-forget; no-op for other engines.
        if appSettings.effectiveAIProcessingEnabled, appSettings.effectiveAIEngine == .appleIntelligence {
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                Task { await LocalAIService().prewarm() }
            }
            #endif
        }

        // Step 1: Transcription
        guard !Task.isCancelled else { return }
        if transcribe {
            // Check for saved transcript on disk first
            if let saved = loadSavedTranscript(for: recording) {
                let stepIndex = appState.processingSteps.count
                appState.processingSteps.append(ProcessingStep(name: "Loaded saved transcript", status: .inProgress))
                recording.transcription = saved
                appState.processingSteps[stepIndex].status = .completed
            } else {
                let stepIndex = appState.processingSteps.count
                let stepName: String = {
                    switch appSettings.effectiveTranscriptionEngine {
                    case .appleSpeech: "Transcribing (Apple Speech)"
                    case .localWhisper: "Transcribing (Local Whisper)"
                    case .parakeetLocal: "Transcribing (Parakeet)"
                    case .remoteEndpoint: "Transcribing audio"
                    }
                }()
                appState.processingSteps.append(ProcessingStep(name: stepName, status: .inProgress))
                do {
                    let txStart = Date()
                    let stepResult = try await transcribeRecordingAudio(recording: recording, stepIndex: stepIndex)
                    let result = stepResult.transcription
                    perfTranscriptionTime = Date().timeIntervalSince(txStart)
                    perfInferenceTime = result.inferenceTime
                    perfDiarizationTime = result.diarizationTime
                    perfSpellCorrectionTime = stepResult.spellCorrectionTime
                    perfTranscriptionModel = transcriptionModelDisplayName
                    perfAudioDuration = recording.duration
                    // Lifetime odometer of audio transcribed by dBrief (survives "Clear stats").
                    appSettings.lifetimeTranscribedSeconds += recording.duration
                    recording.transcription = result
                    appState.processingSteps[stepIndex].status = .completed
                    if let warnings = result.warnings, !warnings.isEmpty {
                        appState.processingSteps.append(
                            ProcessingStep(
                                name: "Transcription warnings",
                                status: .failed(warnings.joined(separator: "\n"))
                            )
                        )
                    }
                    // Persist transcript to disk for retry resilience
                    saveTranscript(result, for: recording)
                    // Resolve diarized speakers against the voice library (Phase 2):
                    // confident matches become real names automatically. Load the
                    // library unconditionally (cheap) so we can also suppress the
                    // ordinal-name guess when a library exists but no embeddings
                    // were produced — the case that caused the "swapped labels" bug.
                    let library = await voiceLibraryStore.load()
                    let hasLibrary = !library.people.isEmpty
                    var resolved: [String: ResolvedSpeaker] = [:]
                    var allDecisions: [String: VoiceIdentityResolver.Decision] = [:]
                    if let embeddings = result.speakerEmbeddings, !embeddings.isEmpty, hasLibrary {
                        let roster = recording.participants
                            + (recording.calendarEvent?.attendees.map(\.name) ?? [])
                        let decisions = VoiceIdentityResolver.resolve(
                            clusterEmbeddings: embeddings, library: library, roster: roster)
                        allDecisions = decisions
                        for (sid, d) in decisions where d.reason == .matched {
                            if let name = d.name {
                                resolved[sid] = ResolvedSpeaker(name: name, personId: d.personId)
                            }
                        }
                        // Per-speaker decision log (cosine + reason) — kept for support
                        // and threshold calibration; cheap, runs only when diarized.
                        for sid in embeddings.keys.sorted() {
                            let emb = embeddings[sid] ?? []
                            let scores = library.people.map { p -> String in
                                let s = p.voiceprints.reduce(Float(-1)) { max($0, VoiceMatch.cosineSimilarity(emb, $1.embedding)) }
                                return "\(p.name)=\(String(format: "%.3f", s))"
                            }.joined(separator: " ")
                            let d = decisions[sid]
                            Logger.transcription.info("VoiceID \(sid, privacy: .public): [\(scores, privacy: .public)] → \(d?.reason.rawValue ?? "nil", privacy: .public) name=\(d?.name ?? "-", privacy: .public) conf=\(String(format: "%.3f", d?.confidence ?? 0), privacy: .public)")
                        }
                        Logger.transcription.info("Voice library matched \(resolved.count) of \(embeddings.count) speaker(s)")
                    } else if hasLibrary {
                        Logger.transcription.error("Voice library present but no speaker embeddings on this recording — speakers left unnamed (no ordinal guess)")
                    }
                    // Build and save rich transcript. Resolved (voice-matched) identities
                    // win; when a library exists, unmatched speakers stay "Speaker N"
                    // rather than getting an arbitrary ordinal participant guess.
                    let rich = richTranscriptBuilder.build(
                        from: result, participants: recording.participants,
                        resolved: resolved, suppressOrdinalGuess: hasLibrary)
                    recording.richTranscript = rich
                    try? await transcriptStore.save(rich, for: recording)

                    // Confirm-first: pause here instead of auto-enrolling + running AI,
                    // when there is something to review. Otherwise behave exactly as before.
                    let speakerCount = Set(rich.segments.compactMap { $0.speakerId }).count
                    let shouldHold = SpeakerReviewGate.shouldHold(
                        mode: appSettings.speakerIdMode,
                        speakerCount: speakerCount,
                        libraryCount: library.people.count)

                    if shouldHold {
                        let embeddings = result.speakerEmbeddings ?? [:]
                        let items: [SpeakerReviewItem] = rich.speakerLabels.map { label in
                            let d = allDecisions[label.id]
                            return SpeakerReviewItem(
                                id: label.id,
                                proposedName: label.displayName,
                                reason: d?.reason ?? .noEmbedding,
                                confidence: d?.confidence ?? 0,
                                personId: label.personId,
                                clusterEmbedding: embeddings[label.id] ?? [],
                                snippet: SpeakerSnippet.representative(for: label.id, in: rich))
                        }.sorted { $0.id < $1.id }
                        appState.pendingSpeakerReview = SpeakerReviewSession(
                            recording: recording,
                            masterAudioURL: recording.finalizedAudioURL,
                            items: items,
                            transcribe: transcribe,
                            summary: summary, actionItems: actionItems, tags: tags,
                            localAIAvailable: localAIAvailable,
                            perf: TranscriptionPerf(
                                model: perfTranscriptionModel, time: perfTranscriptionTime,
                                inference: perfInferenceTime, diarization: perfDiarizationTime,
                                spellCorrection: perfSpellCorrectionTime, finalization: perfFinalizationTime,
                                audioDuration: perfAudioDuration))
                        appState.recordingStatusNote = "Waiting for speaker confirmation"
                        SpeakerReviewWindowController.shared.show()
                        sendReviewReadyNotification()
                        Logger.transcription.info("Confirm-first: holding \(items.count) speaker(s) for review")
                    } else {
                        // Enroll named speakers' voiceprints into the global voice library.
                        if let embeddings = result.speakerEmbeddings, !embeddings.isEmpty {
                            for entry in VoiceEnrollment.enrollable(speakerLabels: rich.speakerLabels, embeddings: embeddings) {
                                await voiceLibraryStore.upsert(
                                    name: entry.name,
                                    voiceprint: Voiceprint(embedding: entry.embedding, model: "fluidaudio-wespeaker-256", capturedAt: Date())
                                )
                            }
                        }
                    }
                } catch {
                    let msg = error.localizedDescription
                    Logger.transcription.error("Transcription failed: \(msg, privacy: .public)")
                    appState.processingSteps[stepIndex].status = .failed(msg)
                }
            }
        }

        // Confirm-first gate: when a hold was armed during Step 1, stop here. The
        // review window's Confirm/Cancel resumes via finishReview / cancelReview.
        if appState.pendingSpeakerReview?.recording === recording { return }

        await runAnalysisAndExport(
            recording: recording,
            transcribe: transcribe,
            summary: summary,
            actionItems: actionItems,
            tags: tags,
            localAIAvailable: localAIAvailable,
            perf: TranscriptionPerf(
                model: perfTranscriptionModel, time: perfTranscriptionTime,
                inference: perfInferenceTime, diarization: perfDiarizationTime,
                spellCorrection: perfSpellCorrectionTime, finalization: perfFinalizationTime,
                audioDuration: perfAudioDuration)
        )
    }

    /// Steps 2–4 of processing (AI analysis → title+markdown → integration dispatch)
    /// plus completion. Extracted so confirm-first can run it after the user confirms
    /// speaker names, and the optimistic path can call it inline. Behavior unchanged.
    private func runAnalysisAndExport(
        recording: Recording,
        transcribe: Bool,
        summary: Bool,
        actionItems: Bool,
        tags: Bool,
        localAIAvailable: Bool,
        perf: TranscriptionPerf
    ) async {
        // AI-side performance, added to the transcription-side metrics in `perf`.
        var perfAIModel: String?
        var perfAITime: TimeInterval?
        var perfTitleGenerationTime: TimeInterval?

        // Step 2: AI tasks (run sequentially to avoid TaskGroup @MainActor issues)
        guard !Task.isCancelled else { return }
        if appSettings.effectiveAIProcessingEnabled, let transcription = recording.transcription {
            let aiEngine = appSettings.effectiveAIEngine
            let endpoint = appSettings.effectiveDefaultAIEndpoint
            let localAvailable = localAIAvailable

            // Pre-flight memory check — informational, non-blocking
            let remoteAIEndpoint = appSettings.effectiveDefaultAIEndpoint
            appState.preflightWarning = RecordingManager.preflightCheck(
                engine: aiEngine,
                hasRemoteEndpoint: remoteAIEndpoint != nil
            )

            let summaryStepIndex = summary ? appendAIStep(
                labelForSummary(engine: aiEngine)
            ) : nil
            let actionStepIndex = actionItems ? appendAIStep(
                labelForActionItems(engine: aiEngine)
            ) : nil
            let tagsStepIndex = tags ? appendAIStep(
                labelForTags(engine: aiEngine)
            ) : nil

            // The rich transcript carries the user's speaker labels; when a saved
            // transcript was loaded (skipping the fresh-transcription build above),
            // load it from the sidecar so relabels reach the AI prompts.
            if recording.richTranscript == nil {
                recording.richTranscript = try? await transcriptStore.load(for: recording)
            }

            let speakerNames = Dictionary(
                (recording.richTranscript?.speakerLabels ?? []).map { ($0.id, $0.displayName) },
                uniquingKeysWith: { first, _ in first }
            )
            let analysisTranscript = transcription.textForLLM(speakerNames: speakerNames)
            let roster = AnalysisRoster.hint(
                participants: recording.participants,
                attendees: recording.calendarEvent?.attendees.map(\.name) ?? []
            )

            let aiStart = Date()
            switch aiEngine {
            case .appleIntelligence:
                await runAppleIntelligenceUnifiedTasks(
                    transcription: analysisTranscript,
                    roster: roster,
                    localAvailable: localAvailable,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            case .qwenLocal:
                await runLocalQwenTasks(
                    transcription: analysisTranscript,
                    roster: roster,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            case .remoteEndpoint:
                await runRemoteAITasks(
                    transcription: analysisTranscript,
                    roster: roster,
                    endpoint: endpoint,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            case .localCLI:
                await runLocalCLITasks(
                    transcription: analysisTranscript,
                    roster: roster,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            }
            // Only log AI timing when at least one task produced output, so a
            // failed/unreachable engine doesn't pollute the averages.
            if recording.summary != nil || recording.actionItems != nil || recording.tags != nil {
                perfAITime = Date().timeIntervalSince(aiStart)
                perfAIModel = aiModelDisplayName
            }
        }

        var generatedMarkdownURL: URL?

        // Step 3: Generate title & write Markdown
        if transcribe || summary || actionItems || tags {
            // Gemma local and the Local CLI generate `title_concept` inline in the
            // JSON analysis (see runLocalQwenTasks / runLocalCLITasks). Skip the
            // separate title call for them so a remote endpoint — if configured —
            // doesn't override the inline title.
            let engine = appSettings.effectiveAIEngine
            if engine != .qwenLocal, engine != .localCLI, engine != .appleIntelligence,
               let transcriptionText = recording.transcription?.textForLLM,
               !transcriptionText.isEmpty {
                let language = recording.transcription?.language
                // Prefer the generated summary as input — titles from a distilled
                // summary are more topical than titles from the first 500 chars.
                let titleInput = recording.summary ?? String(transcriptionText.prefix(500))
                let titleStepIndex = appState.processingSteps.count
                appState.processingSteps.append(ProcessingStep(name: "Generating Title", status: .inProgress))
                do {
                    if shouldGenerateTitle(for: recording),
                       engine == .remoteEndpoint,
                       let endpoint = appSettings.effectiveDefaultAIEndpoint {
                        let titleStart = Date()
                        recording.generatedTitle = try await aiService.generateTitle(
                            transcription: titleInput,
                            language: language,
                            endpoint: endpoint
                        )
                        perfTitleGenerationTime = Date().timeIntervalSince(titleStart)
                    }
                    appState.processingSteps[titleStepIndex].status = .completed
                } catch {
                    // Title generation is non-critical — fall back to text extraction
                    appState.processingSteps[titleStepIndex].status = .completed
                }
            }

            // Logged here (after title generation) so the title-generation time is
            // captured; the helper guards on transcription/AI timing being present.
            logModelPerformance(
                label: performanceLabel(for: recording),
                transcriptionModel: perf.model,
                audioDuration: perf.audioDuration,
                transcriptionTime: perf.time,
                inferenceTime: perf.inference,
                diarizationTime: perf.diarization,
                finalizationTime: perf.finalization,
                aiModel: perfAIModel,
                aiTime: perfAITime,
                spellCorrectionTime: perf.spellCorrection,
                titleGenerationTime: perfTitleGenerationTime
            )

            let stepIndex = appState.processingSteps.count
            appState.processingSteps.append(ProcessingStep(name: "Writing Markdown", status: .inProgress))

            do {
                let outputFolder = resolveMarkdownOutputFolder(for: recording)
                let transcriptionEndpoint: Endpoint? = switch appSettings.effectiveTranscriptionEngine {
                case .appleSpeech: Endpoint(name: "Apple Speech", baseURL: "", modelName: "Apple Speech")
                case .localWhisper: Endpoint(name: "WhisperKit", baseURL: "", modelName: "\(appSettings.whisperModelName) (CoreML)")
                case .parakeetLocal: Endpoint(name: "Parakeet", baseURL: "", modelName: "\(appSettings.parakeetModelVariant) (CoreML)")
                case .remoteEndpoint: appSettings.effectiveDefaultTranscriptionEndpoint
                }
                let aiEndpoint: Endpoint? = switch appSettings.effectiveAIEngine {
                case .appleIntelligence: Endpoint(name: "Apple Intelligence", baseURL: "", modelName: "Apple Intelligence")
                case .qwenLocal: Endpoint(name: "Gemma 4 E4B Local", baseURL: "", modelName: "gemma-4-e4b-4bit (MLX)")
                case .remoteEndpoint: appSettings.effectiveDefaultAIEndpoint
                case .localCLI: Endpoint(name: "Local CLI", baseURL: "", modelName: "Local CLI")
                }
                generatedMarkdownURL = try markdownGenerator.generate(
                    recording: recording,
                    outputFolder: outputFolder,
                    transcriptionEndpoint: transcriptionEndpoint,
                    aiEndpoint: aiEndpoint,
                    includeTranscript: appSettings.obsidianIncludeTranscript
                )
                appState.processingSteps[stepIndex].status = .completed
                persistGeneratedTitle(for: recording)
                await writeInsightsSidecar(for: recording, markdownURL: generatedMarkdownURL)
            } catch {
                appState.processingSteps[stepIndex].status = .failed(error.localizedDescription)
            }
        }

        // Step 4: Integration dispatch
        if hasEnabledIntegrations {
            let results = await integrationDispatchService.dispatch(
                recording: recording,
                settings: appSettings,
                generatedMarkdownURL: generatedMarkdownURL
            )

            for result in results {
                let stepIndex = appState.processingSteps.count
                appState.processingSteps.append(
                    ProcessingStep(
                        name: "Send: \(result.destination.displayName)",
                        status: .inProgress
                    )
                )
                switch result.status {
                case .success, .skipped:
                    appState.processingSteps[stepIndex].status = .completed
                case .failed:
                    appState.processingSteps[stepIndex].status = .failed(result.message)
                }
            }
        }

        appState.recordingState = .idle

        // Send completion notification
        let failedCount = appState.processingSteps.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
        sendCompletionNotification(
            fileName: recording.fileName,
            failed: failedCount
        )
    }

    /// Confirm-first: the user accepted/corrected speaker names. Apply them to the
    /// rich transcript, enroll the named speakers' voiceprints, then resume the
    /// held pipeline (AI → markdown → integrations).
    func finishReview(confirmed: [String: ConfirmedSpeaker]) async {
        guard let session = appState.pendingSpeakerReview else { return }
        let recording = session.recording
        appState.pendingSpeakerReview = nil
        appState.recordingStatusNote = nil

        var loaded = recording.richTranscript
        if loaded == nil { loaded = try? await transcriptStore.load(for: recording) }
        if var transcript = loaded {
            for (speakerId, c) in confirmed {
                let name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                transcript = SpeakerReassignment.rename(transcript, speakerId: speakerId, to: name, personId: c.personId)
            }
            recording.richTranscript = transcript
            try? await transcriptStore.save(transcript, for: recording)
            // Enroll confirmed, named speakers (best-effort, deduped by upsert).
            for (speakerId, c) in confirmed {
                let name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != speakerId else { continue }
                _ = await enrollVoiceprintOnRename(recording: recording, speakerId: speakerId, name: name)
            }
        }

        await resumeAfterReview(session: session, recording: recording)
    }

    /// Confirm-first: the user cancelled/closed the review. Keep the resolver's own
    /// names (the rich transcript is already built) and resume so nothing is stranded.
    func cancelReview() async {
        guard let session = appState.pendingSpeakerReview else { return }
        appState.pendingSpeakerReview = nil
        appState.recordingStatusNote = nil
        await resumeAfterReview(session: session, recording: session.recording)
    }

    /// Shared tail of finish/cancel: the fresh-transcription hold resumes the AI →
    /// markdown → export pipeline; a transcript-viewer re-diarize only commits the
    /// names (already applied + persisted) and signals the open viewer to reload —
    /// re-analysis stays an explicit choice via the viewer's reanalysis banner.
    private func resumeAfterReview(session: SpeakerReviewSession, recording: Recording) async {
        switch session.origin {
        case .pipeline:
            await runAnalysisAndExport(
                recording: recording,
                transcribe: session.transcribe,
                summary: session.summary, actionItems: session.actionItems,
                tags: session.tags, localAIAvailable: session.localAIAvailable,
                perf: session.perf)
        case .rediarize:
            appState.speakerReviewCommit = SpeakerReviewCommit(
                recordingID: recording.id, token: UUID(), offerReanalysis: true)
        }
    }

    /// Confirm-first re-diarize from the transcript viewer: resolve the freshly
    /// re-diarized turns against the voice library, persist the rebuilt transcript,
    /// and present the review window — mirroring the fresh-transcription hold.
    /// Returns `true` when a hold was armed; `false` when there's nothing to review
    /// (the caller then commits the diarization silently, as in optimistic mode).
    func presentReDiarizeReview(recording: Recording, turns: [DiarizedTurn],
                                embeddings: [String: [Float]], baseTranscript: RichTranscript) async -> Bool {
        var transcript = SpeakerAssigner.assign(turns, to: baseTranscript)
        let speakerIds = Set(transcript.segments.compactMap { $0.speakerId }).sorted()
        let library = await voiceLibraryStore.load()
        guard SpeakerReviewGate.shouldHold(
            mode: appSettings.speakerIdMode,
            speakerCount: speakerIds.count,
            libraryCount: library.people.count) else { return false }

        // Resolve clusters against the library (matched identities pre-fill the cards).
        var decisions: [String: VoiceIdentityResolver.Decision] = [:]
        if !embeddings.isEmpty, !library.people.isEmpty {
            let roster = recording.participants
                + (recording.calendarEvent?.attendees.map(\.name) ?? [])
            decisions = VoiceIdentityResolver.resolve(
                clusterEmbeddings: embeddings, library: library, roster: roster)
        }
        // Matched names win; unmatched speakers stay "Speaker N".
        transcript.speakerLabels = speakerIds.map { sid in
            if let d = decisions[sid], d.reason == .matched, let name = d.name {
                return SpeakerLabel(id: sid, displayName: name, personId: d.personId)
            }
            return SpeakerLabel(id: sid, displayName: sid)
        }
        recording.richTranscript = transcript
        try? await transcriptStore.save(transcript, for: recording)

        let items: [SpeakerReviewItem] = transcript.speakerLabels.map { label in
            let d = decisions[label.id]
            return SpeakerReviewItem(
                id: label.id,
                proposedName: label.displayName,
                reason: d?.reason ?? .noEmbedding,
                confidence: d?.confidence ?? 0,
                personId: label.personId,
                clusterEmbedding: embeddings[label.id] ?? [],
                snippet: SpeakerSnippet.representative(for: label.id, in: transcript))
        }.sorted { $0.id < $1.id }

        appState.pendingSpeakerReview = SpeakerReviewSession(
            recording: recording,
            masterAudioURL: recording.finalizedAudioURL,
            items: items,
            transcribe: false, summary: false, actionItems: false, tags: false,
            localAIAvailable: false, perf: TranscriptionPerf(),
            origin: .rediarize)
        SpeakerReviewWindowController.shared.show()
        sendReviewReadyNotification()
        Logger.transcription.info("Confirm-first re-diarize: holding \(items.count) speaker(s) for review")
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
    func retryAIAnalysis(for recording: Recording) async {
        guard appState.recordingState != .processing else { return }

        // Load transcript from disk if not already in memory
        if recording.transcription == nil {
            guard let saved = loadSavedTranscript(for: recording) else { return }
            recording.transcription = saved
        }

        // The rich transcript carries the user's speaker labels; load it from the
        // sidecar when it isn't already in memory so relabels reach the AI prompts.
        if recording.richTranscript == nil {
            recording.richTranscript = try? await transcriptStore.load(for: recording)
        }

        // Clear previous AI results and any stale memory warning
        appState.preflightWarning = nil
        recording.summary = nil
        recording.actionItems = nil
        recording.tags = nil
        recording.sentiment = nil
        recording.generatedTitle = nil

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

        // Set up processing state
        appState.currentRecording = recording
        appState.recordingState = .processing
        appState.processingSteps = []
        appState.liveInferenceText = nil

        // Measured AI performance for this retry session (logged below).
        var perfAIModel: String?
        var perfAITime: TimeInterval?

        // Step 2: AI tasks (same as processRecording)
        if appSettings.effectiveAIProcessingEnabled, let transcription = recording.transcription {
            let aiEngine = appSettings.effectiveAIEngine
            let endpoint = appSettings.effectiveDefaultAIEndpoint
            let localAvailable = localAIAvailable

            // Pre-flight memory check — informational, non-blocking
            let remoteAIEndpoint = appSettings.effectiveDefaultAIEndpoint
            appState.preflightWarning = RecordingManager.preflightCheck(
                engine: aiEngine,
                hasRemoteEndpoint: remoteAIEndpoint != nil
            )

            let summaryStepIndex = appendAIStep(labelForSummary(engine: aiEngine))
            let actionStepIndex = appendAIStep(labelForActionItems(engine: aiEngine))
            let tagsStepIndex = appendAIStep(labelForTags(engine: aiEngine))

            let speakerNames = Dictionary(
                (recording.richTranscript?.speakerLabels ?? []).map { ($0.id, $0.displayName) },
                uniquingKeysWith: { first, _ in first }
            )
            let analysisTranscript = transcription.textForLLM(speakerNames: speakerNames)
            let roster = AnalysisRoster.hint(
                participants: recording.participants,
                attendees: recording.calendarEvent?.attendees.map(\.name) ?? []
            )

            let aiStart = Date()
            switch aiEngine {
            case .appleIntelligence:
                await runAppleIntelligenceUnifiedTasks(
                    transcription: analysisTranscript,
                    roster: roster,
                    localAvailable: localAvailable,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            case .qwenLocal:
                await runLocalQwenTasks(
                    transcription: analysisTranscript,
                    roster: roster,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            case .remoteEndpoint:
                await runRemoteAITasks(
                    transcription: analysisTranscript,
                    roster: roster,
                    endpoint: endpoint,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            case .localCLI:
                await runLocalCLITasks(
                    transcription: analysisTranscript,
                    roster: roster,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            }
            if recording.summary != nil || recording.actionItems != nil || recording.tags != nil {
                perfAITime = Date().timeIntervalSince(aiStart)
                perfAIModel = aiModelDisplayName
            }
        }

        logModelPerformance(
            label: performanceLabel(for: recording),
            transcriptionModel: nil,
            audioDuration: nil,
            transcriptionTime: nil,
            inferenceTime: nil,
            aiModel: perfAIModel,
            aiTime: perfAITime
        )

        var generatedMarkdownURL: URL?

        // Step 3: Generate title & write Markdown
        let engine = appSettings.effectiveAIEngine
        // Skip the separate title call for the unified-JSON engines (Gemma, Local CLI,
        // Apple Intelligence) — they produce `title_concept` inline.
        if engine != .qwenLocal, engine != .localCLI, engine != .appleIntelligence,
           let transcriptionText = recording.transcription?.textForLLM,
           !transcriptionText.isEmpty {
            let language = recording.transcription?.language
            let titleInput = recording.summary ?? String(transcriptionText.prefix(500))
            let titleStepIndex = appState.processingSteps.count
            appState.processingSteps.append(ProcessingStep(name: "Generating Title", status: .inProgress))
            do {
                if shouldGenerateTitle(for: recording),
                   engine == .remoteEndpoint,
                   let endpoint = appSettings.effectiveDefaultAIEndpoint {
                    recording.generatedTitle = try await aiService.generateTitle(
                        transcription: titleInput,
                        language: language,
                        endpoint: endpoint
                    )
                }
                appState.processingSteps[titleStepIndex].status = .completed
            } catch {
                // Title generation is non-critical — fall back to text extraction
                appState.processingSteps[titleStepIndex].status = .completed
            }
        }

        // Write Markdown for every engine (the unified engines set the title inline above).
        let markdownStepIndex = appState.processingSteps.count
        appState.processingSteps.append(ProcessingStep(name: "Writing Markdown", status: .inProgress))
        do {
            let outputFolder = resolveMarkdownOutputFolder(for: recording)
            let transcriptionEndpoint: Endpoint? = switch appSettings.effectiveTranscriptionEngine {
            case .appleSpeech: Endpoint(name: "Apple Speech", baseURL: "", modelName: "Apple Speech")
            case .localWhisper: Endpoint(name: "WhisperKit", baseURL: "", modelName: "\(appSettings.whisperModelName) (CoreML)")
            case .parakeetLocal: Endpoint(name: "Parakeet", baseURL: "", modelName: "\(appSettings.parakeetModelVariant) (CoreML)")
            case .remoteEndpoint: appSettings.effectiveDefaultTranscriptionEndpoint
            }
            let aiEndpoint: Endpoint? = switch appSettings.effectiveAIEngine {
            case .appleIntelligence: Endpoint(name: "Apple Intelligence", baseURL: "", modelName: "Apple Intelligence")
            case .qwenLocal: Endpoint(name: "Gemma 4 E4B Local", baseURL: "", modelName: "gemma-4-e4b-4bit (MLX)")
            case .remoteEndpoint: appSettings.effectiveDefaultAIEndpoint
            case .localCLI: Endpoint(name: "Local CLI", baseURL: "", modelName: "Local CLI")
            }
            generatedMarkdownURL = try markdownGenerator.generate(
                recording: recording,
                outputFolder: outputFolder,
                transcriptionEndpoint: transcriptionEndpoint,
                aiEndpoint: aiEndpoint,
                includeTranscript: appSettings.obsidianIncludeTranscript
            )
            appState.processingSteps[markdownStepIndex].status = .completed
            persistGeneratedTitle(for: recording)
            await writeInsightsSidecar(for: recording, markdownURL: generatedMarkdownURL)
        } catch {
            appState.processingSteps[markdownStepIndex].status = .failed(error.localizedDescription)
        }

        // Step 4: Integration dispatch
        if hasEnabledIntegrations {
            let results = await integrationDispatchService.dispatch(
                recording: recording,
                settings: appSettings,
                generatedMarkdownURL: generatedMarkdownURL
            )

            for result in results {
                let stepIndex = appState.processingSteps.count
                appState.processingSteps.append(
                    ProcessingStep(
                        name: "Send: \(result.destination.displayName)",
                        status: .inProgress
                    )
                )
                switch result.status {
                case .success, .skipped:
                    appState.processingSteps[stepIndex].status = .completed
                case .failed:
                    appState.processingSteps[stepIndex].status = .failed(result.message)
                }
            }
        }

        appState.recordingState = .idle

        // Send completion notification
        let failedCount = appState.processingSteps.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
        sendCompletionNotification(
            fileName: recording.fileName,
            failed: failedCount
        )
    }

    func startProcessing(transcribe: Bool, summary: Bool, actionItems: Bool, tags: Bool) {
        processingTask = Task {
            await processRecording(transcribe: transcribe, summary: summary, actionItems: actionItems, tags: tags)
            processingTask = nil
        }
    }

    func startProcessingQueue() {
        processingTask = Task {
            await processQueue()
            processingTask = nil
        }
    }

    func cancelProcessing() async {
        processingTask?.cancel()
        processingTask = nil
        appState.liveInferenceText = nil
        for i in appState.processingSteps.indices {
            if case .inProgress = appState.processingSteps[i].status {
                appState.processingSteps[i].status = .failed("Cancelled by user")
            }
        }
        appState.recordingState = .idle
        await forceReleaseGPU()
    }

    func pickFileForTranscription() {
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

        guard response == .OK, let url = panel.url else { return }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let recording = Recording(
            fileURL: url,
            fileSize: size,
            meetingTitleDraft: defaultMeetingTitle(from: nil),
            finalizedAudioURL: nil
        )
        appState.currentRecording = recording
        appState.showPostRecordingSheet = true

        // Probe the picked file's duration asynchronously and update the
        // observable recording so the sheet shows a real time instead of 0:00.
        Task { @MainActor in
            let probed = await durationSeconds(for: url)
            if probed > 0 { recording.duration = probed }
        }
    }

    // MARK: - YouTube

    /// Download audio from a YouTube (or any yt-dlp-supported) URL, then show
    /// the post-recording sheet so the user can set options before processing.
    func loadYouTubeAudio(from urlString: String) async throws {
        let (audioURL, videoTitle) = try await youtubeDownloadService.downloadAudio(from: urlString)  // actor hop

        let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
        let size = (attrs?[.size] as? Int64) ?? 0

        let sanitizedTitle = videoTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? "youtube-video" : videoTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        let recording = Recording(
            fileURL: audioURL,
            fileSize: size,
            meetingTitleDraft: sanitizedTitle
        )
        // Relocate the downloaded file into the recordings folder during finalization
        // (no DSP re-encode — it's already a finished m4a) so it lands in history and
        // the transcript viewer like a normal recording.
        recording.importSourceURL = audioURL
        recording.duration = await durationSeconds(for: audioURL)
        appState.currentRecording = recording
        appState.showPostRecordingSheet = true
    }

    // MARK: - Watched Folders

    /// Headlessly transcribe + analyze a file dropped into a watched folder, using the
    /// global auto-processing preferences. The user's original file is left untouched: it's
    /// copied into a temp location and imported (relocated) into the recordings folder via
    /// the same path as YouTube imports, so it lands in History with outputs in dBrief's
    /// folders rather than scattering sidecars next to the source.
    func processWatchedFile(_ sourceURL: URL) async {
        guard appState.recordingState == .idle else { return }

        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)
        } catch {
            appState.lastError = "Watched folder: couldn't read \(sourceURL.lastPathComponent). \(error.localizedDescription)"
            return
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let title = sourceURL.deletingPathExtension().lastPathComponent

        let recording = Recording(
            fileURL: sourceURL,
            fileSize: size,
            meetingTitleDraft: title
        )
        recording.importSourceURL = tempURL
        recording.duration = await durationSeconds(for: tempURL)

        // Re-check idleness: the user may have started a recording while we awaited
        // AVFoundation's duration probe. Don't clobber a live recording's state.
        guard appState.recordingState == .idle else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        appState.currentRecording = recording

        await processRecording(
            transcribe: appSettings.autoTranscribe,
            summary: appSettings.autoSummary && appSettings.autoTranscribe,
            actionItems: appSettings.autoActionItems && appSettings.autoTranscribe,
            tags: appSettings.autoTags && appSettings.autoTranscribe
        )
    }

    func skipProcessing() async {
        if let recording = appState.currentRecording {
            do {
                try await ensureRecordingFinalized(recording: recording)
            } catch {
                appState.lastError = error.localizedDescription
                return
            }
        }
        appState.showPostRecordingSheet = false
        appState.recordingState = .idle
    }

    /// Discards the current post-recording recording: removes its on-disk audio
    /// (the captured scratch tracks if not yet finalized, otherwise the finalized
    /// master + sidecars) and returns to idle without processing. Backs the
    /// post-recording sheet's Delete action.
    func discardRecording() async {
        defer {
            appState.currentRecording = nil
            appState.showPostRecordingSheet = false
            appState.recordingState = .idle
        }
        guard let recording = appState.currentRecording else { return }

        var urls: [URL] = [recording.fileURL]
        if let tracks = recording.capturedTracks {
            urls.append(contentsOf: [tracks.systemURL, tracks.micURL].compactMap { $0 })
        }
        if let finalized = recording.finalizedAudioURL { urls.append(finalized) }
        if let metadata = recording.metadataURL { urls.append(metadata) }
        urls.append(contentsOf: recording.segmentAudioURLs)

        let fm = FileManager.default
        for url in Set(urls) {
            try? fm.removeItem(at: url)
        }
        recording.capturedTracks = nil
    }

    func queueForLater(
        transcribe: Bool,
        summary: Bool,
        actionItems: Bool,
        tags: Bool
    ) async {
        guard let recording = appState.currentRecording else { return }

        do {
            try await ensureRecordingFinalized(recording: recording)
        } catch {
            appState.lastError = error.localizedDescription
            return
        }

        let item = QueueItem(
            transcribe: transcribe,
            summary: summary && transcribe,
            actionItems: actionItems && transcribe,
            tags: tags && transcribe,
            titleWasUserProvided: recording.titleWasUserProvided
        )

        do {
            try saveQueueItem(item, for: recording)
        } catch {
            appState.lastError = error.localizedDescription
            return
        }

        appState.showPostRecordingSheet = false
        appState.recordingState = .idle
        appState.queuedCount = discoverQueuedItems().count
    }

    func processQueue() async {
        guard appState.recordingState != .processing else { return }

        let queued = discoverQueuedItems()
        guard !queued.isEmpty else { return }

        for (audioURL, item) in queued {
            let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            let name = audioURL.deletingPathExtension().lastPathComponent

            let recording = Recording(
                fileURL: audioURL,
                fileSize: size,
                meetingTitleDraft: name,
                finalizedAudioURL: audioURL
            )
            recording.titleWasUserProvided = item.titleWasUserProvided

            appState.currentRecording = recording
            await processRecording(
                transcribe: item.transcribe,
                summary: item.summary,
                actionItems: item.actionItems,
                tags: item.tags
            )

            Self.removeQueueFile(for: audioURL)
        }

        appState.queuedCount = discoverQueuedItems().count
    }

    func purgeLocalWhisperModel() async throws {
        try await localAIPluginService.purgeWhisperModel()
    }

    func purgeLocalQwenModel() async throws {
        try await localAIPluginService.purgeQwenModel()
    }

    func purgeLocalParakeetModel() async throws {
        try await parakeetService.purgeModels()
    }

    /// True when models may be downloaded (no active recording/processing that
    /// would contend for the GPU mutex and the shared state stream).
    var canDownloadModels: Bool {
        appState.recordingState == .idle
    }

    /// True when no recording or processing is in flight — safe for the watched-folder
    /// poller to start a headless transcription.
    var isIdle: Bool {
        appState.recordingState == .idle
    }

    /// Fetch the list of available WhisperKit model variants from HuggingFace,
    /// routed through the helper process. Returns [] on failure (caller falls back).
    func fetchAvailableWhisperModels() async -> [String] {
        await localAIPluginService.fetchAvailableWhisperModels(repo: "argmaxinc/whisperkit-coreml")
    }

    /// Best-effort check for whether the model selected for `kind` is cached.
    func isModelCached(_ kind: LocalModelKind) async -> Bool {
        switch kind {
        case .whisper:
            return await localAIPluginService.isWhisperModelCached(name: appSettings.whisperModelName)
        case .parakeet:
            return await parakeetService.isModelDownloaded()
        case .gemma:
            return await localAIPluginService.isLLMModelCached()
        }
    }

    /// Start downloading the selected model for `kind`. When `forceRedownload`
    /// is true the engine's cache is purged first so the model is re-fetched.
    func downloadModel(_ kind: LocalModelKind, forceRedownload: Bool = false) {
        guard canDownloadModels else { return }

        downloadObservers[kind]?.cancel()
        downloadTasks[kind]?.cancel()
        modelDownloads[kind] = .downloading(progress: nil, label: "Starting…")

        let stream = (kind == .parakeet)
            ? parakeetService.stateStream
            : localAIPluginService.stateStream

        downloadObservers[kind] = Task { @MainActor [weak self] in
            for await state in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                if let phase = ModelDownloadPhase.from(pluginState: state) {
                    self.modelDownloads[kind] = phase
                }
            }
        }

        downloadTasks[kind] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if forceRedownload {
                    try? await self.purgeModel(kind)
                }
                switch kind {
                case .whisper:
                    let config = WhisperRuntimeConfig(
                        modelName: self.appSettings.whisperModelName,
                        language: self.appSettings.transcriptionLanguage.isEmpty ? nil : self.appSettings.transcriptionLanguage,
                        diarizationEnabled: false
                    )
                    try await self.localAIPluginService.downloadWhisperModel(config: config)
                case .parakeet:
                    try await self.parakeetService.prepareModel(variant: self.appSettings.parakeetModelVariant)
                case .gemma:
                    try await self.localAIPluginService.downloadLLMModel()
                }
                // Tear down the observer before writing the terminal state so a
                // late stream element can't overwrite it.
                self.downloadObservers[kind]?.cancel()
                self.downloadObservers[kind] = nil
                self.modelDownloads[kind] = .idle
            } catch is CancellationError {
                self.downloadObservers[kind]?.cancel()
                self.downloadObservers[kind] = nil
                self.modelDownloads[kind] = .idle
            } catch {
                self.downloadObservers[kind]?.cancel()
                self.downloadObservers[kind] = nil
                self.modelDownloads[kind] = .failed(error.localizedDescription)
            }
        }
    }

    /// Cancel an in-flight download and reset its row to idle.
    func cancelDownload(_ kind: LocalModelKind) {
        downloadObservers[kind]?.cancel()
        downloadObservers[kind] = nil
        downloadTasks[kind]?.cancel()
        downloadTasks[kind] = nil
        modelDownloads[kind] = .idle
    }

    /// Cancel every in-flight model download (e.g. when a recording starts).
    func cancelAllActiveDownloads() {
        for kind in LocalModelKind.allCases {
            if case .downloading = modelDownloads[kind] ?? .idle {
                cancelDownload(kind)
            }
        }
    }

    private func purgeModel(_ kind: LocalModelKind) async throws {
        switch kind {
        case .whisper: try await purgeLocalWhisperModel()
        case .parakeet: try await purgeLocalParakeetModel()
        case .gemma: try await purgeLocalQwenModel()
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

    /// One guided-generation call producing summary, action items, tags, sentiment, and
    /// an inline title. Mirrors `runLocalQwenTasks`: the three step indices are all
    /// completed by the single call, so the progress UI stays consistent across engines.
    private func runAppleIntelligenceUnifiedTasks(
        transcription: String,
        roster: String?,
        localAvailable: Bool,
        summaryStepIndex: Int?,
        actionStepIndex: Int?,
        tagsStepIndex: Int?,
        recording: Recording
    ) async {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else {
            let message = "Apple Intelligence requires macOS 26+."
            markFailed(summaryStepIndex, message)
            markFailed(actionStepIndex, message)
            markFailed(tagsStepIndex, message)
            return
        }
        guard localAvailable else {
            let message = "Apple Intelligence is unavailable. Ensure it is enabled and your System + Siri languages match."
            markFailed(summaryStepIndex, message)
            markFailed(actionStepIndex, message)
            markFailed(tagsStepIndex, message)
            return
        }
        guard summaryStepIndex != nil || actionStepIndex != nil || tagsStepIndex != nil else { return }

        let contextualTranscription = CalendarEvent.augment(prompt: transcription, with: recording.calendarEvent, roster: roster)
        do {
            let insights = try await LocalAIService().analyzeTranscript(
                contextualTranscription,
                outputLanguage: appSettings.outputLanguage,
                customVocabulary: appSettings.effectiveCustomVocabulary.joined(separator: ", "),
                summaryGuidance: appSettings.effectiveSummaryPrompt,
                actionItemsGuidance: appSettings.effectiveActionItemsPrompt,
                tagsGuidance: appSettings.effectiveTagsPrompt
            )

            if let summaryStepIndex {
                recording.summary = insights.summary
                markCompleted(summaryStepIndex)
            }
            applyGeneratedTitle(insights.titleConcept, to: recording)
            if let actionStepIndex {
                recording.actionItems = insights.actionItems
                markCompleted(actionStepIndex)
            }
            if let tagsStepIndex {
                recording.tags = insights.tags
                recording.sentiment = insights.sentiment
                markCompleted(tagsStepIndex)
            }
        } catch is CancellationError {
            let message = "Cancelled by user"
            markFailed(summaryStepIndex, message)
            markFailed(actionStepIndex, message)
            markFailed(tagsStepIndex, message)
        } catch {
            let message = error.localizedDescription
            markFailed(summaryStepIndex, message)
            markFailed(actionStepIndex, message)
            markFailed(tagsStepIndex, message)
        }
        #else
        let message = "Apple Intelligence is unavailable in this build."
        markFailed(summaryStepIndex, message)
        markFailed(actionStepIndex, message)
        markFailed(tagsStepIndex, message)
        #endif
    }

    /// The user's configured Summary / Action Items / Tags prompts bundled for the
    /// unified (single-call) engines — Gemma and Local CLI — so they honor the same
    /// prompts the Remote Endpoint already uses. The unified prompt keeps ownership of
    /// the JSON envelope; these only drive per-field content/style.
    private var effectiveInsightsGuidance: InsightsGuidance {
        InsightsGuidance(
            summary: appSettings.effectiveSummaryPrompt,
            actionItems: appSettings.effectiveActionItemsPrompt,
            tags: appSettings.effectiveTagsPrompt
        )
    }

    private func runLocalQwenTasks(
        transcription: String,
        roster: String?,
        summaryStepIndex: Int?,
        actionStepIndex: Int?,
        tagsStepIndex: Int?,
        recording: Recording
    ) async {
        guard summaryStepIndex != nil || actionStepIndex != nil || tagsStepIndex != nil else { return }
        let contextualTranscription = CalendarEvent.augment(prompt: transcription, with: recording.calendarEvent, roster: roster)
        do {
            let insights = try await withPluginStepAdapter(stepIndex: firstNonNil(summaryStepIndex, actionStepIndex, tagsStepIndex)) {
                let stream = await self.localAIPluginService.analyzeTranscriptStream(
                    contextualTranscription,
                    outputLanguage: self.appSettings.outputLanguage,
                    customVocabulary: self.appSettings.effectiveCustomVocabulary.joined(separator: ", "),
                    guidance: self.effectiveInsightsGuidance
                )
                
                var chunks: [String] = []
                var lastUIUpdate = ContinuousClock.now
                let uiThrottle: ContinuousClock.Duration = .milliseconds(200)

                for try await chunk in stream {
                    chunks.append(chunk)

                    // Throttle UI updates to avoid starving the Metal GPU
                    // with SwiftUI re-renders while MLX inference is running.
                    let now = ContinuousClock.now
                    if now - lastUIUpdate >= uiThrottle {
                        let snapshot = chunks.joined()
                        await MainActor.run { self.appState.liveInferenceText = snapshot }
                        lastUIUpdate = now
                    }
                }

                let fullJSON = chunks.joined()
                // Push the final snapshot — throttled updates may have skipped
                // the last chunks on fast generations, and the previous clear
                // here could blank the view after a single flash.
                await MainActor.run { self.appState.liveInferenceText = fullJSON }

                return try LocalInsightsDecoder.decodeAndNormalize(fullJSON)
            }

            if let summaryStepIndex {
                recording.summary = insights.summary
                markCompleted(summaryStepIndex)
            }
            applyGeneratedTitle(insights.titleConcept, to: recording)
            if let actionStepIndex {
                recording.actionItems = insights.actionItems
                markCompleted(actionStepIndex)
            }
            if let tagsStepIndex {
                recording.tags = insights.tags
                recording.sentiment = insights.sentiment
                markCompleted(tagsStepIndex)
            }
        } catch is CancellationError {
            let message = "Cancelled by user"
            markFailed(summaryStepIndex, message)
            markFailed(actionStepIndex, message)
            markFailed(tagsStepIndex, message)
        } catch {
            let message = error.localizedDescription
            markFailed(summaryStepIndex, message)
            markFailed(actionStepIndex, message)
            markFailed(tagsStepIndex, message)
        }
    }

    /// Runs the unified-JSON analysis through the user-configured Local CLI command.
    /// Mirrors `runLocalQwenTasks` (one call producing summary, action items, tags,
    /// sentiment, and an inline title) but invokes a subprocess instead of MLX and
    /// does not stream.
    private func runLocalCLITasks(
        transcription: String,
        roster: String?,
        summaryStepIndex: Int?,
        actionStepIndex: Int?,
        tagsStepIndex: Int?,
        recording: Recording
    ) async {
        guard summaryStepIndex != nil || actionStepIndex != nil || tagsStepIndex != nil else { return }
        let contextualTranscription = CalendarEvent.augment(prompt: transcription, with: recording.calendarEvent, roster: roster)
        do {
            let insights = try await localCLIService.analyze(
                transcript: contextualTranscription,
                outputLanguage: appSettings.outputLanguage,
                config: appSettings.localCLIConfig,
                customVocabulary: appSettings.effectiveCustomVocabulary.joined(separator: ", "),
                summaryGuidance: appSettings.effectiveSummaryPrompt,
                actionItemsGuidance: appSettings.effectiveActionItemsPrompt,
                tagsGuidance: appSettings.effectiveTagsPrompt
            )

            if let summaryStepIndex {
                recording.summary = insights.summary
                markCompleted(summaryStepIndex)
            }
            applyGeneratedTitle(insights.titleConcept, to: recording)
            if let actionStepIndex {
                recording.actionItems = insights.actionItems
                markCompleted(actionStepIndex)
            }
            if let tagsStepIndex {
                recording.tags = insights.tags
                recording.sentiment = insights.sentiment
                markCompleted(tagsStepIndex)
            }
        } catch is CancellationError {
            let message = "Cancelled by user"
            markFailed(summaryStepIndex, message)
            markFailed(actionStepIndex, message)
            markFailed(tagsStepIndex, message)
        } catch {
            let message = error.localizedDescription
            markFailed(summaryStepIndex, message)
            markFailed(actionStepIndex, message)
            markFailed(tagsStepIndex, message)
        }
    }

    /// Appends the user's custom-vocabulary "spell these exactly" block to a remote
    /// per-task system prompt (no-op when no vocabulary is configured).
    private func withVocabulary(_ prompt: String) -> String {
        prompt + UnifiedInsightsPrompt.vocabularyBlock(appSettings.effectiveCustomVocabulary.joined(separator: ", "))
    }

    private func runRemoteAITasks(
        transcription: String,
        roster: String?,
        endpoint: Endpoint?,
        summaryStepIndex: Int?,
        actionStepIndex: Int?,
        tagsStepIndex: Int?,
        recording: Recording
    ) async {
        guard let endpoint else {
            let message = AIServiceError.invalidEndpoint.localizedDescription
            markFailed(summaryStepIndex, message)
            markFailed(actionStepIndex, message)
            markFailed(tagsStepIndex, message)
            return
        }

        if let summaryStepIndex {
            do {
                recording.summary = try await aiService.generateSummary(
                    transcription: transcription,
                    endpoint: endpoint,
                    systemPrompt: withVocabulary(CalendarEvent.augment(prompt: appSettings.effectiveSummaryPrompt, with: recording.calendarEvent, roster: roster))
                )
                markCompleted(summaryStepIndex)
            } catch {
                markFailed(summaryStepIndex, error.localizedDescription)
            }
        }

        if let actionStepIndex {
            do {
                recording.actionItems = try await aiService.extractActionItems(
                    transcription: transcription,
                    endpoint: endpoint,
                    systemPrompt: withVocabulary(CalendarEvent.augment(prompt: appSettings.effectiveActionItemsPrompt, with: recording.calendarEvent, roster: roster))
                )
                markCompleted(actionStepIndex)
            } catch {
                markFailed(actionStepIndex, error.localizedDescription)
            }
        }

        if let tagsStepIndex {
            do {
                let result = try await aiService.analyzeTags(
                    transcription: transcription,
                    endpoint: endpoint,
                    systemPrompt: withVocabulary(appSettings.effectiveTagsPrompt)
                )
                recording.tags = result.tags
                recording.sentiment = result.sentiment
                markCompleted(tagsStepIndex)
            } catch {
                markFailed(tagsStepIndex, error.localizedDescription)
            }
        }
    }

    private func withPluginStepAdapter<T>(
        stepIndex: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let stateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await state in localAIPluginService.stateStream {
                if Task.isCancelled { return }
                applyPluginState(state, toStepIndex: stepIndex)
            }
        }

        defer { stateTask.cancel() }
        return try await operation()
    }

    private func withParakeetStepAdapter<T>(
        stepIndex: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let stateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await state in parakeetService.stateStream {
                if Task.isCancelled { return }
                applyParakeetState(state, toStepIndex: stepIndex)
            }
        }
        defer { stateTask.cancel() }
        return try await operation()
    }

    private func applyParakeetState(_ state: LocalAIPluginState, toStepIndex stepIndex: Int) {
        guard appState.processingSteps.indices.contains(stepIndex) else { return }
        switch state {
        case .idle:
            break
        case .transcribing:
            appState.processingSteps[stepIndex].name = "Transcribing (Parakeet)"
        case .newSegments:
            break // Parakeet doesn't produce live segments
        case .diarizing:
            appState.processingSteps[stepIndex].name = "Identifying speakers"
        case .analyzing:
            break
        case .downloading(let progress, let stage):
            appState.processingSteps[stepIndex].progress = progress
            switch stage {
            case .parakeetModel:
                appState.processingSteps[stepIndex].name = "Downloading Parakeet model…"
            case .parakeetModelLoading:
                appState.processingSteps[stepIndex].name = "Loading Parakeet model…"
                appState.processingSteps[stepIndex].progress = nil
            case .speakerKitModel:
                appState.processingSteps[stepIndex].name = "Downloading speaker model…"
            default:
                break
            }
        }
    }

    private func applyPluginState(_ state: LocalAIPluginState, toStepIndex stepIndex: Int) {
        guard appState.processingSteps.indices.contains(stepIndex) else { return }
        switch state {
        case .idle:
            break
        case .transcribing:
            appState.processingSteps[stepIndex].name = "Transcribing (Local WhisperKit)"
        case .newSegments(let segments):
            appState.liveTranscriptSegments.append(contentsOf: segments)
            return // don't update step name
        case .diarizing:
            appState.processingSteps[stepIndex].name = "Identifying speakers"
        case .analyzing:
            appState.processingSteps[stepIndex].name = "Analyzing transcript (Gemma 4 E4B local)"
        case .downloading(let progress, let stage):
            appState.processingSteps[stepIndex].progress = progress
            switch stage {
            case .whisperModel:
                appState.processingSteps[stepIndex].name = "Downloading WhisperKit model…"
            case .whisperModelLoading:
                appState.processingSteps[stepIndex].name = "Loading WhisperKit model…"
                appState.processingSteps[stepIndex].progress = nil // loading is indeterminate
            case .llmModel:
                appState.processingSteps[stepIndex].name = "Downloading Gemma model"
            case .speakerKitModel:
                appState.processingSteps[stepIndex].name = "Downloading SpeakerKit model"
            case .parakeetModel:
                appState.processingSteps[stepIndex].name = "Downloading Parakeet model…"
            case .parakeetModelLoading:
                appState.processingSteps[stepIndex].name = "Loading Parakeet model…"
                appState.processingSteps[stepIndex].progress = nil
            case .ttsModel:
                appState.processingSteps[stepIndex].name = "Downloading TTS model…"
            case .ttsModelLoading:
                appState.processingSteps[stepIndex].name = "Loading TTS model…"
                appState.processingSteps[stepIndex].progress = nil
            case .kokoroTTSModel:
                appState.processingSteps[stepIndex].name = "Downloading Kokoro voice model…"
            case .kokoroTTSModelLoading:
                appState.processingSteps[stepIndex].name = "Loading Kokoro voice model…"
                appState.processingSteps[stepIndex].progress = nil
            }
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

    /// Friendly name of the transcription model for the active engine, matching
    /// the names shown in the Model Performance panel.
    private var transcriptionModelDisplayName: String {
        switch appSettings.effectiveTranscriptionEngine {
        case .appleSpeech:
            return "Apple Speech"
        case .localWhisper:
            return WhisperModelInfo.parse(appSettings.whisperModelName).displayName
        case .parakeetLocal:
            return ParakeetModelInfo.find(appSettings.parakeetModelVariant).displayName
        case .remoteEndpoint:
            let endpoint = appSettings.effectiveDefaultTranscriptionEndpoint
            let name = endpoint?.modelName.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? "Remote Endpoint" : name
        }
    }

    /// Friendly name of the AI-analysis model for the active engine.
    private var aiModelDisplayName: String {
        switch appSettings.effectiveAIEngine {
        case .appleIntelligence:
            return "Apple Intelligence"
        case .qwenLocal:
            return "Gemma 4 E4B Local"
        case .remoteEndpoint:
            let endpoint = appSettings.effectiveDefaultAIEndpoint
            let name = endpoint?.modelName.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? "Remote Endpoint" : name
        case .localCLI:
            return "Local CLI"
        }
    }

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
    private struct TranscriptionStepResult {
        let transcription: TranscriptionResult
        let spellCorrectionTime: TimeInterval?
    }

    private func transcribeRecordingAudio(
        recording: Recording,
        stepIndex: Int
    ) async throws -> TranscriptionStepResult {
        let raw: TranscriptionResult
        if !recording.segmentAudioURLs.isEmpty {
            raw = try await transcribeSegmentedAudio(recording: recording, stepIndex: stepIndex)
        } else {
            raw = try await transcribeSingleAudioFile(
                recording.fileURL,
                stepIndex: stepIndex,
                segmentIndex: nil,
                segmentCount: nil
            )
        }
        // Engine-agnostic cleanup: always strip hallucination/markup noise; strip filler
        // words only when the user opted in; drop ignored-phrase segments (Whisper
        // silence-hallucinations) when enabled. Applies uniformly across all engines.
        let cleaned = TranscriptCleanup.clean(
            raw,
            removeFillerWords: appSettings.effectiveRemoveFillerWords,
            ignoredSegments: appSettings.effectiveIgnoredSegments
        )

        // Vocabulary spelling: re-spell the user's custom-vocabulary terms via the
        // AI engine (the reliable replacement for Whisper decoder-prompt biasing).
        // No-op when no vocabulary is set or no AI engine is available.
        guard !appSettings.effectiveCustomVocabulary.isEmpty else {
            return TranscriptionStepResult(transcription: cleaned, spellCorrectionTime: nil)
        }
        if appState.processingSteps.indices.contains(stepIndex) {
            appState.processingSteps[stepIndex].name = "Correcting vocabulary…"
        }
        let speller = TranscriptSpellingService(appSettings: appSettings, localPlugin: localAIPluginService)
        let spellStart = Date()
        let corrected = await speller.correct(cleaned)
        return TranscriptionStepResult(
            transcription: corrected,
            spellCorrectionTime: Date().timeIntervalSince(spellStart)
        )
    }

    private func transcribeSegmentedAudio(
        recording: Recording,
        stepIndex: Int
    ) async throws -> TranscriptionResult {
        let segments = recording.segmentAudioURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !segments.isEmpty else {
            return try await transcribeSingleAudioFile(
                recording.fileURL,
                stepIndex: stepIndex,
                segmentIndex: nil,
                segmentCount: nil
            )
        }

        var pieces: [SegmentTranscriptionPiece] = []
        pieces.reserveCapacity(segments.count)
        var cumulativeOffset = 0.0
        var warnings: [String] = []
        var language: String?
        // Sum the per-segment model/diarization times so the Benchmark breakdown
        // works for long (segmented) recordings, not just single-file ones.
        var inferenceSum: TimeInterval?
        var diarizationSum: TimeInterval?

        for (index, segmentURL) in segments.enumerated() {
            let segmentNumber = index + 1
            if appState.processingSteps.indices.contains(stepIndex) {
                appState.processingSteps[stepIndex].name = "Transcribing audio (segment \(segmentNumber)/\(segments.count))"
            }

            let result = try await transcribeSingleAudioFile(
                segmentURL,
                stepIndex: stepIndex,
                segmentIndex: segmentNumber,
                segmentCount: segments.count
            )
            if let inf = result.inferenceTime { inferenceSum = (inferenceSum ?? 0) + inf }
            if let diar = result.diarizationTime { diarizationSum = (diarizationSum ?? 0) + diar }
            if language == nil, let detected = result.language, !detected.isEmpty {
                language = detected
            }
            if let segmentWarnings = result.warnings, !segmentWarnings.isEmpty {
                warnings.append(contentsOf: segmentWarnings.map { "Segment \(segmentNumber): \($0)" })
            }

            pieces.append(
                SegmentTranscriptionPiece(
                    offsetSeconds: cumulativeOffset,
                    text: result.text,
                    segments: result.segments,
                    speakerEmbeddings: result.speakerEmbeddings
                )
            )
            let segmentDuration = await durationSeconds(for: segmentURL)
            let fallbackDuration = result.segments.last?.end ?? 1
            cumulativeOffset += max(segmentDuration, fallbackDuration, 1)
        }

        let merged = Self.mergeSegmentTranscriptions(pieces)
        return TranscriptionResult(
            text: merged.text,
            segments: merged.segments,
            language: language,
            warnings: warnings.isEmpty ? nil : warnings,
            speakerCount: merged.speakerCount,
            inferenceTime: inferenceSum,
            diarizationTime: diarizationSum,
            speakerEmbeddings: merged.speakerEmbeddings
        )
    }

    private func transcribeSingleAudioFile(
        _ url: URL,
        stepIndex: Int,
        segmentIndex: Int?,
        segmentCount: Int?
    ) async throws -> TranscriptionResult {
        switch appSettings.effectiveTranscriptionEngine {
        case .appleSpeech:
            let language = appSettings.effectiveTranscriptionLanguage
            // macOS 26+ uses the modern SpeechAnalyzer (better accuracy, word-level
            // timestamps); older systems and unsupported locales fall back to the
            // legacy SFSpeechRecognizer-based service.
            if #available(macOS 26, *) {
                let locale = language.isEmpty ? Locale.current : Locale(identifier: language)
                if await AppleSpeechAnalyzerService.supports(locale: locale) {
                    return try await AppleSpeechAnalyzerService().transcribe(
                        fileURL: url,
                        language: language,
                        status: { [weak self] statusText in
                            guard let self else { return }
                            Task { @MainActor in
                                guard self.appState.processingSteps.indices.contains(stepIndex) else { return }
                                self.appState.processingSteps[stepIndex].name = statusText
                            }
                        }
                    )
                }
            }
            return try await localTranscriptionService.transcribe(
                fileURL: url,
                language: language
            )
        case .localWhisper:
            let whisperConfig = appSettings.whisperRuntimeConfig
            return try await withPluginStepAdapter(stepIndex: stepIndex) {
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
            return try await withParakeetStepAdapter(stepIndex: stepIndex) {
                try await self.parakeetService.transcribe(
                    fileURL: url,
                    language: self.appSettings.transcriptionLanguage.isEmpty ? nil : self.appSettings.transcriptionLanguage,
                    modelVariant: self.appSettings.parakeetModelVariant,
                    diarize: self.appSettings.diarizationEnabled
                )
            }
        case .remoteEndpoint:
            guard let endpoint = appSettings.effectiveDefaultTranscriptionEndpoint else {
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
                language: appSettings.effectiveTranscriptionLanguage,
                // Custom vocabulary is intentionally NOT sent as the ASR prompt:
                // the only remote consumers of initialPrompt are Whisper-family
                // servers (OpenAI-compatible `prompt` / whisper-asr `initial_prompt`),
                // which share Whisper's prompt fragility (it can blank out large
                // stretches of audio). Deepgram/ElevenLabs ignore it entirely.
                // Vocabulary spelling is applied uniformly post-transcription via
                // TranscriptSpellingService in transcribeRecordingAudio.
                initialPrompt: "",
                diarize: appSettings.diarizationEnabled,
                chunking: .init(
                    enabled: appSettings.remoteChunkingEnabled,
                    maxUploadMB: appSettings.remoteChunkMaxUploadMB,
                    overlapSeconds: appSettings.remoteChunkOverlapSeconds,
                    retryCount: appSettings.remoteChunkRetryCount
                ),
                progress: { [weak self] progress in
                    guard let self else { return }
                    Task { @MainActor in
                        guard self.appState.processingSteps.indices.contains(stepIndex) else { return }
                        self.appState.processingSteps[stepIndex].name =
                            "Transcribing \(segmentLabel) (chunk \(progress.current)/\(progress.total))"
                    }
                }
            )
        }
    }

    private func ensureRecordingFinalized(recording: Recording) async throws {
        if recording.finalizedAudioURL != nil {
            return
        }

        let meetingTitle = recording.meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if meetingTitle.isEmpty {
            recording.meetingTitleDraft = defaultMeetingTitle(from: recording.associatedApp)
        }

        // Skip segmentation for local transcription engines (they handle long files natively)
        let segmentationEnabled = appSettings.effectiveTranscriptionEngine != .localWhisper
            && appSettings.effectiveTranscriptionEngine != .parakeetLocal

        // Pre-encoded imports (e.g. YouTube downloads) are already finished audio;
        // relocate them into the recordings folder instead of running capture DSP,
        // so they appear in history and the transcript viewer like any recording.
        if let importSource = recording.importSourceURL {
            let result = try await recordingFinalizer.importExistingAudio(
                sourceURL: importSource,
                recording: recording,
                baseFolder: appSettings.effectiveRecordingFolderURL,
                segmentationEnabled: segmentationEnabled
            )
            recording.importSourceURL = nil
            recording.fileURL = result.masterAudioURL
            recording.finalizedAudioURL = result.masterAudioURL
            recording.segmentAudioURLs = result.segmentAudioURLs
            recording.metadataURL = result.metadataURL
            recording.finalizationWarnings = result.warnings
            if let attrs = try? FileManager.default.attributesOfItem(atPath: result.masterAudioURL.path),
               let size = attrs[FileAttributeKey.size] as? Int64
            {
                recording.fileSize = size
            }
            return
        }

        let tracks = recording.capturedTracks ?? CapturedTracks(systemURL: nil, micURL: recording.fileURL)
        let result = try await recordingFinalizer.finalize(
            tracks: tracks,
            recording: recording,
            baseFolder: appSettings.effectiveRecordingFolderURL,
            segmentationEnabled: segmentationEnabled,
            echoSuppressionEnabled: recording.echoSuppressionApplied
        )
        recording.capturedTracks = nil  // scratch files have been consumed

        recording.fileURL = result.masterAudioURL
        recording.finalizedAudioURL = result.masterAudioURL
        recording.segmentAudioURLs = result.segmentAudioURLs
        recording.metadataURL = result.metadataURL
        recording.finalizationWarnings = result.warnings

        if let attrs = try? FileManager.default.attributesOfItem(atPath: result.masterAudioURL.path),
           let size = attrs[FileAttributeKey.size] as? Int64
        {
            recording.fileSize = size
        }

        // Re-probe the encoded master for the authoritative duration so exported
        // markdown, integrations, and the results view reflect the real length
        // even if the stop-time estimate was off (or never captured).
        let masterDuration = await durationSeconds(for: result.masterAudioURL)
        if masterDuration > 0 {
            recording.duration = masterDuration
        }
    }

    /// Sum of the on-disk sizes of the captured per-track CAF files. Missing
    /// files contribute 0 so a single absent track never zeroes the total.
    static func totalTrackFileSize(_ tracks: CapturedTracks?) -> Int64 {
        guard let tracks else { return 0 }
        let urls = [tracks.systemURL, tracks.micURL].compactMap { $0 }
        var total: Int64 = 0
        for url in urls {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64
            {
                total += size
            }
        }
        return total
    }

    private func durationSeconds(for fileURL: URL) async -> Double {
        let asset = AVURLAsset(url: fileURL)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 {
                return seconds
            }
        } catch {
            return 0
        }
        return 0
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


    private static func generateRawCaptureBaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dbrief-raw-\(UUID().uuidString)")
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

    private func persistGeneratedTitle(for recording: Recording) {
        let title = recording.generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, let audioURL = recording.finalizedAudioURL else { return }
        let metaURL = audioURL.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? Data(contentsOf: metaURL),
              var payload = try? JSONDecoder().decode(RecordingMetadataPayload.self, from: data) else { return }
        guard payload.generatedTitle != title else { return }
        payload.generatedTitle = title
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let out = try? encoder.encode(payload) else { return }
        do {
            try out.write(to: metaURL, options: .atomic)
        } catch {
            Logger.recording.error("Failed to persist generated title to metadata sidecar: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeInsightsSidecar(for recording: Recording, markdownURL: URL?) async {
        guard let summary = recording.summary, !summary.isEmpty else { return }
        let insights = RecordingInsights(
            summary: summary,
            actionItems: recording.actionItems ?? [],
            tags: recording.tags ?? [],
            sentiment: recording.sentiment ?? "",
            markdownPath: markdownURL?.path
        )
        do {
            try await insightsStore.save(insights, for: recording)
        } catch {
            Logger.recording.error("Failed to write insights sidecar: \(error.localizedDescription, privacy: .public)")
        }
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

    private static func queueURL(for recording: Recording) -> URL? {
        guard let audioURL = recording.finalizedAudioURL else { return nil }
        return audioURL.deletingPathExtension().appendingPathExtension("queue.json")
    }

    private func saveQueueItem(_ item: QueueItem, for recording: Recording) throws {
        guard let url = Self.queueURL(for: recording) else {
            throw NSError(domain: "RecordingManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot determine queue file path — recording not finalized."
            ])
        }
        let data = try JSONEncoder().encode(item)
        try data.write(to: url, options: .atomic)
    }

    private static func removeQueueFile(for audioURL: URL) {
        let queueURL = audioURL.deletingPathExtension().appendingPathExtension("queue.json")
        try? FileManager.default.removeItem(at: queueURL)
    }

    func discoverQueuedItems() -> [(audioURL: URL, item: QueueItem)] {
        let folder = appSettings.effectiveRecordingFolderURL
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [(url: URL, date: Date, item: QueueItem)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "json",
                  fileURL.lastPathComponent.hasSuffix(".queue.json") else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let item = try? JSONDecoder().decode(QueueItem.self, from: data) else { continue }

            let stem = fileURL.deletingPathExtension().deletingPathExtension()
            let audioURL: URL
            if FileManager.default.fileExists(atPath: stem.appendingPathExtension("m4a").path) {
                audioURL = stem.appendingPathExtension("m4a")
            } else if FileManager.default.fileExists(atPath: stem.appendingPathExtension("flac").path) {
                audioURL = stem.appendingPathExtension("flac")
            } else {
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: [.creationDateKey])
            let date = values?.creationDate ?? .distantPast
            results.append((url: audioURL, date: date, item: item))
        }

        return results
            .sorted { $0.date < $1.date }
            .map { ($0.url, $0.item) }
    }

    /// Derives the transcript JSON path from the finalized audio URL.
    private static func transcriptURL(for recording: Recording) -> URL? {
        guard let audioURL = recording.finalizedAudioURL else { return nil }
        return audioURL.deletingPathExtension().appendingPathExtension("transcript.json")
    }

    /// Saves the transcription result as JSON alongside the audio file.
    private func saveTranscript(_ result: TranscriptionResult, for recording: Recording) {
        guard let url = Self.transcriptURL(for: recording) else { return }
        do {
            let data = try JSONEncoder().encode(result)
            try data.write(to: url, options: .atomic)
            recording.transcriptURL = url
        } catch {
            // Non-critical: log but don't fail the pipeline
        }
    }

    /// Loads a previously saved transcription from disk.
    private func loadSavedTranscript(for recording: Recording) -> TranscriptionResult? {
        let url = recording.transcriptURL ?? Self.transcriptURL(for: recording)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(TranscriptionResult.self, from: data) else {
            return nil
        }
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
        let embeddings = recording.transcription?.speakerEmbeddings
            ?? loadSavedTranscript(for: recording)?.speakerEmbeddings
        guard let embedding = embeddings?[speakerId], !embedding.isEmpty else { return nil }
        let id = await voiceLibraryStore.upsert(
            name: trimmed,
            voiceprint: Voiceprint(embedding: embedding, model: "fluidaudio-wespeaker-256", capturedAt: Date()))
        Logger.transcription.info("Enrolled voiceprint for a manually-named speaker")
        return id.isEmpty ? nil : id
    }

    /// Speaker ids with a non-empty voice embedding available right now (from the
    /// in-memory transcription or the persisted `.transcript.json` sidecar) — i.e.
    /// the speakers that `enrollVoiceprintOnRename` could enroll.
    func embeddedSpeakerIds(for recording: Recording) -> Set<String> {
        let embeddings = recording.transcription?.speakerEmbeddings
            ?? loadSavedTranscript(for: recording)?.speakerEmbeddings
        guard let embeddings else { return [] }
        return Set(embeddings.filter { !$0.value.isEmpty }.keys)
    }

    private var hasEnabledIntegrations: Bool {
        let integrations = appSettings.integrations
        return integrations.appleNotes.enabled
            || integrations.appleReminders.enabled
            || integrations.webhook.enabled
    }

    struct SegmentTranscriptionPiece: Sendable {
        let offsetSeconds: Double
        let text: String
        let segments: [TranscriptionResult.Segment]
        let speakerEmbeddings: [String: [Float]]?

        init(
            offsetSeconds: Double,
            text: String,
            segments: [TranscriptionResult.Segment],
            speakerEmbeddings: [String: [Float]]? = nil
        ) {
            self.offsetSeconds = offsetSeconds
            self.text = text
            self.segments = segments
            self.speakerEmbeddings = speakerEmbeddings
        }
    }

    nonisolated static func mergeSegmentTranscriptions(_ pieces: [SegmentTranscriptionPiece]) -> TranscriptionResult {
        // Unify each part's independently-diarized speakers into one global space.
        let reconciled = SegmentSpeakerReconciler.reconcile(
            pieces.map { .init(segments: $0.segments, speakerEmbeddings: $0.speakerEmbeddings) }
        )

        var fullTextParts: [String] = []
        var mergedSegments: [TranscriptionResult.Segment] = []

        for (index, piece) in pieces.enumerated() {
            let remap = reconciled.remaps[index]
            let trimmed = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                fullTextParts.append(trimmed)
            }

            for segment in piece.segments {
                let globalSpeaker = segment.speaker.flatMap { remap[$0] }
                let remappedWords = segment.words?.map { word -> TranscriptionResult.Word in
                    var w = word
                    if let s = word.speaker { w.speaker = remap[s] }
                    return w
                }
                mergedSegments.append(
                    .init(
                        start: segment.start + piece.offsetSeconds,
                        end: segment.end + piece.offsetSeconds,
                        text: segment.text,
                        words: remappedWords,
                        speaker: globalSpeaker
                    )
                )
            }
        }

        return TranscriptionResult(
            text: fullTextParts.joined(separator: " "),
            segments: mergedSegments,
            speakerCount: reconciled.speakerCount == 0 ? nil : reconciled.speakerCount,
            speakerEmbeddings: reconciled.speakerEmbeddings.isEmpty ? nil : reconciled.speakerEmbeddings
        )
    }
}
