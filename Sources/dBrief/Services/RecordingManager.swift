
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

    init(appState: AppState, appSettings: AppSettings, transcriptStore: TranscriptStore, insightsStore: InsightsStore, modelPerformanceStore: ModelPerformanceStore, microsoftAuthService: MicrosoftAuthService) {
        self.appState = appState
        self.appSettings = appSettings
        self.transcriptStore = transcriptStore
        self.insightsStore = insightsStore
        self.modelPerformanceStore = modelPerformanceStore
        self.microsoftAuthService = microsoftAuthService
        self.outlookCalendarService = OutlookCalendarService(authService: microsoftAuthService)
        self.localAIPluginService = LocalAIPluginService(connection: mlHost)
        self.parakeetService = ParakeetTranscriptionService(connection: mlHost)
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

        let started = recording.date
        switch appSettings.effectiveCalendarSource {
        case .iCal:
            Task { [weak recording] in
                let event = await calendarService.findCurrentEvent(at: started)
                await MainActor.run { recording?.calendarEvent = event }
            }
        case .outlook:
            Task { [weak recording] in
                let event = await outlookCalendarService.findCurrentEvent(at: started)
                await MainActor.run { recording?.calendarEvent = event }
            }
        case .disabled:
            break
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

        miniPlayer?.show()

        observeAudioState()
    }

    func stopRecording() async {
        await audioCaptureManager.stopRecording()

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
        }

        appState.recordingState = .idle
        appState.showPostRecordingSheet = true
        miniPlayer?.dismiss()
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
        appState.liveInferenceText = nil

        // Measured performance for this session (logged at the end).
        var perfTranscriptionModel: String?
        var perfTranscriptionTime: TimeInterval?
        var perfInferenceTime: TimeInterval?
        var perfAudioDuration: TimeInterval?
        var perfAIModel: String?
        var perfAITime: TimeInterval?

        let finalizationStepIndex = appState.processingSteps.count
        appState.processingSteps.append(ProcessingStep(name: "Finalizing audio", status: .inProgress))
        do {
            try await ensureRecordingFinalized(recording: recording)
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
                    let result = try await transcribeRecordingAudio(recording: recording, stepIndex: stepIndex)
                    perfTranscriptionTime = Date().timeIntervalSince(txStart)
                    perfInferenceTime = result.inferenceTime
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
                    // Build and save rich transcript with word-level sync (pass participant names for speaker mapping)
                    let rich = richTranscriptBuilder.build(from: result, participants: recording.participants)
                    recording.richTranscript = rich
                    try? await transcriptStore.save(rich, for: recording)
                } catch {
                    let msg = error.localizedDescription
                    Logger.transcription.error("Transcription failed: \(msg, privacy: .public)")
                    appState.processingSteps[stepIndex].status = .failed(msg)
                }
            }
        }

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

            let aiStart = Date()
            switch aiEngine {
            case .appleIntelligence:
                await runAppleIntelligenceUnifiedTasks(
                    transcription: transcription.textForLLM,
                    localAvailable: localAvailable,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            case .qwenLocal:
                await runLocalQwenTasks(
                    transcription: transcription.textForLLM,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            case .remoteEndpoint:
                await runRemoteAITasks(
                    transcription: transcription.textForLLM,
                    endpoint: endpoint,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            case .localCLI:
                await runLocalCLITasks(
                    transcription: transcription.textForLLM,
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

        logModelPerformance(
            transcriptionModel: perfTranscriptionModel,
            audioDuration: perfAudioDuration,
            transcriptionTime: perfTranscriptionTime,
            inferenceTime: perfInferenceTime,
            aiModel: perfAIModel,
            aiTime: perfAITime
        )

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
                    if engine == .remoteEndpoint,
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

            let aiStart = Date()
            switch aiEngine {
            case .appleIntelligence:
                await runAppleIntelligenceUnifiedTasks(
                    transcription: transcription.textForLLM,
                    localAvailable: localAvailable,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            case .qwenLocal:
                await runLocalQwenTasks(
                    transcription: transcription.textForLLM,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            case .remoteEndpoint:
                await runRemoteAITasks(
                    transcription: transcription.textForLLM,
                    endpoint: endpoint,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            case .localCLI:
                await runLocalCLITasks(
                    transcription: transcription.textForLLM,
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
                if engine == .remoteEndpoint,
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
            tags: tags && transcribe
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

        let contextualTranscription = CalendarEvent.augment(prompt: transcription, with: recording.calendarEvent)
        do {
            let insights = try await LocalAIService().analyzeTranscript(
                contextualTranscription,
                outputLanguage: appSettings.outputLanguage,
                customVocabulary: appSettings.effectiveWhisperPrompt
            )

            if let summaryStepIndex {
                recording.summary = insights.summary
                markCompleted(summaryStepIndex)
            }
            let trimmedTitle = insights.titleConcept.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                let datePrefix = Self.dateOnlyString(recording.date)
                recording.generatedTitle = "\(datePrefix) - \(trimmedTitle)"
            }
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

    private func runLocalQwenTasks(
        transcription: String,
        summaryStepIndex: Int?,
        actionStepIndex: Int?,
        tagsStepIndex: Int?,
        recording: Recording
    ) async {
        guard summaryStepIndex != nil || actionStepIndex != nil || tagsStepIndex != nil else { return }
        let contextualTranscription = CalendarEvent.augment(prompt: transcription, with: recording.calendarEvent)
        do {
            let insights = try await withPluginStepAdapter(stepIndex: firstNonNil(summaryStepIndex, actionStepIndex, tagsStepIndex)) {
                let stream = await self.localAIPluginService.analyzeTranscriptStream(
                    contextualTranscription,
                    outputLanguage: self.appSettings.outputLanguage,
                    customVocabulary: self.appSettings.effectiveWhisperPrompt
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
            if !insights.titleConcept.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                let datePrefix = Self.dateOnlyString(recording.date)
                recording.generatedTitle = "\(datePrefix) - \(insights.titleConcept.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))"
            }
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
        summaryStepIndex: Int?,
        actionStepIndex: Int?,
        tagsStepIndex: Int?,
        recording: Recording
    ) async {
        guard summaryStepIndex != nil || actionStepIndex != nil || tagsStepIndex != nil else { return }
        let contextualTranscription = CalendarEvent.augment(prompt: transcription, with: recording.calendarEvent)
        do {
            let insights = try await localCLIService.analyze(
                transcript: contextualTranscription,
                outputLanguage: appSettings.outputLanguage,
                config: appSettings.localCLIConfig,
                customVocabulary: appSettings.effectiveWhisperPrompt
            )

            if let summaryStepIndex {
                recording.summary = insights.summary
                markCompleted(summaryStepIndex)
            }
            if !insights.titleConcept.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                let datePrefix = Self.dateOnlyString(recording.date)
                recording.generatedTitle = "\(datePrefix) - \(insights.titleConcept.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))"
            }
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
        prompt + UnifiedInsightsPrompt.vocabularyBlock(appSettings.effectiveWhisperPrompt)
    }

    private func runRemoteAITasks(
        transcription: String,
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
                    systemPrompt: withVocabulary(CalendarEvent.augment(prompt: appSettings.effectiveSummaryPrompt, with: recording.calendarEvent))
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
                    systemPrompt: withVocabulary(CalendarEvent.augment(prompt: appSettings.effectiveActionItemsPrompt, with: recording.calendarEvent))
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

    /// Append a performance record for the session, if either pass produced
    /// timing. Fire-and-forget — never blocks or fails the pipeline.
    private func logModelPerformance(
        transcriptionModel: String?,
        audioDuration: TimeInterval?,
        transcriptionTime: TimeInterval?,
        inferenceTime: TimeInterval?,
        aiModel: String?,
        aiTime: TimeInterval?
    ) {
        guard transcriptionTime != nil || aiTime != nil else { return }
        let record = ModelPerformanceRecord(
            transcriptionModel: transcriptionTime != nil ? transcriptionModel : nil,
            audioDuration: transcriptionTime != nil ? audioDuration : nil,
            transcriptionTime: transcriptionTime,
            inferenceTime: transcriptionTime != nil ? inferenceTime : nil,
            aiModel: aiTime != nil ? aiModel : nil,
            aiTime: aiTime
        )
        Task { await modelPerformanceStore.append(record) }
    }

    private func transcribeRecordingAudio(
        recording: Recording,
        stepIndex: Int
    ) async throws -> TranscriptionResult {
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
        // words only when the user opted in. Applies uniformly across all engines.
        return TranscriptCleanup.clean(raw, removeFillerWords: appSettings.effectiveRemoveFillerWords)
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
                    segments: result.segments
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
            warnings: warnings.isEmpty ? nil : warnings
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
                try await self.localAIPluginService.transcribe(
                    fileURL: url,
                    initialPrompt: self.appSettings.effectiveWhisperPrompt,
                    whisperConfig: whisperConfig
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
                initialPrompt: appSettings.effectiveWhisperPrompt,
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
            echoSuppressionEnabled: appSettings.acousticEchoCancellation
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

    private func observeAudioState() {
        Task {
            while audioCaptureManager.isCapturing {
                appState.recordingDuration = audioCaptureManager.duration
                appState.peakLevel = audioCaptureManager.peakLevel
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
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
    }

    nonisolated static func mergeSegmentTranscriptions(_ pieces: [SegmentTranscriptionPiece]) -> TranscriptionResult {
        var fullTextParts: [String] = []
        var mergedSegments: [TranscriptionResult.Segment] = []

        for piece in pieces {
            let trimmed = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                fullTextParts.append(trimmed)
            }

            for segment in piece.segments {
                mergedSegments.append(
                    .init(
                        start: segment.start + piece.offsetSeconds,
                        end: segment.end + piece.offsetSeconds,
                        text: segment.text,
                        words: segment.words
                    )
                )
            }
        }

        return TranscriptionResult(
            text: fullTextParts.joined(separator: " "),
            segments: mergedSegments
        )
    }
}
