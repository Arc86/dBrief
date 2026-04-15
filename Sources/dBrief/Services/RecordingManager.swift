
import Foundation
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
    private let localAIPluginService = LocalAIPluginService()
    /// Exposed for TranscriptChatService — read-only reference, access serialized through actor's AsyncMutex.
    var localPlugin: LocalAIPluginService { localAIPluginService }
    var miniPlayer: FloatingMiniPlayerController?
    private var processingTask: Task<Void, Never>?
    private let aiService = AIService()
    private let markdownGenerator = MarkdownGenerator()
    private let integrationDispatchService = IntegrationDispatchService()
    private let recordingFinalizer = RecordingFinalizer()
    private let transcriptStore: TranscriptStore
    private let richTranscriptBuilder = RichTranscriptBuilder()

    // Memory requirements for local models (bytes)
    private enum MemoryThreshold {
        static let qwen3_4b: Int64 = 4_831_838_209   // 4.5 GB
    }

    init(appState: AppState, appSettings: AppSettings, transcriptStore: TranscriptStore) {
        self.appState = appState
        self.appSettings = appSettings
        self.transcriptStore = transcriptStore
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
            required = MemoryThreshold.qwen3_4b
            modelName = "Qwen3 4B (Local)"
        case .appleIntelligence, .remoteEndpoint:
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
        let rawURL = Self.generateRawCaptureURL()

        let recording = Recording(
            fileURL: rawURL,
            associatedApp: associatedApp,
            meetingTitleDraft: defaultMeetingTitle(from: associatedApp)
        )
        appState.currentRecording = recording

        try await audioCaptureManager.startRecording(
            to: rawURL,
            sampleRate: 16_000,
            bitRate: 128_000,
            inputDeviceUID: appSettings.audioInputDeviceUID
        )
        appState.recordingState = .recording
        miniPlayer?.show()

        observeAudioState()
    }

    func stopRecording() async {
        // Capture actual file URL before stopping (writer gets nilled)
        let actualURL = audioCaptureManager.actualFileURL
        await audioCaptureManager.stopRecording()

        if let recording = appState.currentRecording {
            // Update to actual capture URL from the writer.
            if let actualURL, actualURL != recording.fileURL {
                recording.fileURL = actualURL
            }
            recording.duration = audioCaptureManager.duration
            recording.finalizedAudioURL = nil
            recording.segmentAudioURLs = []
            recording.metadataURL = nil
            recording.finalizationWarnings = []
            if let attrs = try? FileManager.default.attributesOfItem(atPath: recording.fileURL.path),
               let size = attrs[.size] as? Int64
            {
                recording.fileSize = size
            }
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
        appState.processingSteps = []
        appState.liveTranscriptSegments = []

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
                    case .remoteEndpoint: "Transcribing audio"
                    }
                }()
                appState.processingSteps.append(ProcessingStep(name: stepName, status: .inProgress))
                do {
                    let result = try await transcribeRecordingAudio(recording: recording, stepIndex: stepIndex)
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
        if let transcription = recording.transcription {
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

            switch aiEngine {
            case .appleIntelligence:
                await runAppleIntelligenceTasks(
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
            }
        }

        var generatedMarkdownURL: URL?

        // Step 3: Generate title & write Markdown
        if transcribe || summary || actionItems || tags {
            // Generate AI title from transcription
            if let transcriptionText = recording.transcription?.textForLLM, !transcriptionText.isEmpty {
                let language = recording.transcription?.language
                let titleStepIndex = appState.processingSteps.count
                appState.processingSteps.append(ProcessingStep(name: "Generating Title", status: .inProgress))
                do {
                    #if canImport(FoundationModels)
                    if appSettings.effectiveAIEngine == .appleIntelligence, #available(macOS 26, *), localAIAvailable {
                        recording.generatedTitle = try await LocalAIService().generateTitle(
                            transcription: String(transcriptionText.prefix(500)),
                            language: language
                        )
                    } else if let endpoint = appSettings.effectiveDefaultAIEndpoint {
                        recording.generatedTitle = try await aiService.generateTitle(
                            transcription: String(transcriptionText.prefix(500)),
                            language: language,
                            endpoint: endpoint
                        )
                    }
                    #else
                    if let endpoint = appSettings.effectiveDefaultAIEndpoint {
                        recording.generatedTitle = try await aiService.generateTitle(
                            transcription: String(transcriptionText.prefix(500)),
                            language: language,
                            endpoint: endpoint
                        )
                    }
                    #endif
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
                case .remoteEndpoint: appSettings.effectiveDefaultTranscriptionEndpoint
                }
                let aiEndpoint: Endpoint? = switch appSettings.effectiveAIEngine {
                case .appleIntelligence: Endpoint(name: "Apple Intelligence", baseURL: "", modelName: "Apple Intelligence")
                case .qwenLocal: Endpoint(name: "Qwen3 4B Local", baseURL: "", modelName: "Qwen3-4B-Instruct-2507-4bit (MLX)")
                case .remoteEndpoint: appSettings.effectiveDefaultAIEndpoint
                }
                generatedMarkdownURL = try markdownGenerator.generate(
                    recording: recording,
                    outputFolder: outputFolder,
                    transcriptionEndpoint: transcriptionEndpoint,
                    aiEndpoint: aiEndpoint,
                    includeTranscript: appSettings.obsidianIncludeTranscript
                )
                appState.processingSteps[stepIndex].status = .completed
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

        // Clear previous AI results
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

        // Step 2: AI tasks (same as processRecording)
        if let transcription = recording.transcription {
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

            switch aiEngine {
            case .appleIntelligence:
                await runAppleIntelligenceTasks(
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
            }
        }

        var generatedMarkdownURL: URL?

        // Step 3: Generate title & write Markdown
        if let transcriptionText = recording.transcription?.textForLLM, !transcriptionText.isEmpty {
            let language = recording.transcription?.language
            let titleStepIndex = appState.processingSteps.count
            appState.processingSteps.append(ProcessingStep(name: "Generating Title", status: .inProgress))
            do {
                #if canImport(FoundationModels)
                if appSettings.effectiveAIEngine == .appleIntelligence, #available(macOS 26, *), localAIAvailable {
                    recording.generatedTitle = try await LocalAIService().generateTitle(
                        transcription: String(transcriptionText.prefix(500)),
                        language: language
                    )
                } else if let endpoint = appSettings.effectiveDefaultAIEndpoint {
                    recording.generatedTitle = try await aiService.generateTitle(
                        transcription: String(transcriptionText.prefix(500)),
                        language: language,
                        endpoint: endpoint
                    )
                }
                #else
                if let endpoint = appSettings.effectiveDefaultAIEndpoint {
                    recording.generatedTitle = try await aiService.generateTitle(
                        transcription: String(transcriptionText.prefix(500)),
                        language: language,
                        endpoint: endpoint
                    )
                }
                #endif
                appState.processingSteps[titleStepIndex].status = .completed
            } catch {
                // Title generation is non-critical — fall back to text extraction
                appState.processingSteps[titleStepIndex].status = .completed
            }

            let stepIndex = appState.processingSteps.count
            appState.processingSteps.append(ProcessingStep(name: "Writing Markdown", status: .inProgress))

            do {
                let outputFolder = resolveMarkdownOutputFolder(for: recording)
                let transcriptionEndpoint: Endpoint? = switch appSettings.effectiveTranscriptionEngine {
                case .appleSpeech: Endpoint(name: "Apple Speech", baseURL: "", modelName: "Apple Speech")
                case .localWhisper: Endpoint(name: "WhisperKit", baseURL: "", modelName: "\(appSettings.whisperModelName) (CoreML)")
                case .remoteEndpoint: appSettings.effectiveDefaultTranscriptionEndpoint
                }
                let aiEndpoint: Endpoint? = switch appSettings.effectiveAIEngine {
                case .appleIntelligence: Endpoint(name: "Apple Intelligence", baseURL: "", modelName: "Apple Intelligence")
                case .qwenLocal: Endpoint(name: "Qwen3 4B Local", baseURL: "", modelName: "Qwen3-4B-Instruct-2507-4bit (MLX)")
                case .remoteEndpoint: appSettings.effectiveDefaultAIEndpoint
                }
                generatedMarkdownURL = try markdownGenerator.generate(
                    recording: recording,
                    outputFolder: outputFolder,
                    transcriptionEndpoint: transcriptionEndpoint,
                    aiEndpoint: aiEndpoint,
                    includeTranscript: appSettings.obsidianIncludeTranscript
                )
                appState.processingSteps[stepIndex].status = .completed
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

    /// Called by MemoryPressureMonitor when system memory pressure is detected.
    /// Unloads all local AI models to free memory.
    func handleMemoryPressure() async {
        // Unload both Whisper and Qwen models to free GPU/unified memory
        await localAIPluginService.purgeModelsOnMemoryPressure()
    }

    /// Force-release all Metal/GPU resources before app termination.
    func forceReleaseGPU() async {
        await localAIPluginService.forceUnload()
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
        case .qwenLocal: "Generating summary (Qwen3 4B local)"
        case .remoteEndpoint: "Generating summary"
        }
    }

    private func labelForActionItems(engine: AppSettings.AIEngine) -> String {
        switch engine {
        case .appleIntelligence: "Extracting action items (Apple Intelligence)"
        case .qwenLocal: "Extracting action items (Qwen3 4B local)"
        case .remoteEndpoint: "Extracting action items"
        }
    }

    private func labelForTags(engine: AppSettings.AIEngine) -> String {
        switch engine {
        case .appleIntelligence: "Analyzing tags (Apple Intelligence)"
        case .qwenLocal: "Analyzing tags & sentiment (Qwen3 4B local)"
        case .remoteEndpoint: "Analyzing tags & sentiment"
        }
    }

    private func runAppleIntelligenceTasks(
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

        if let summaryStepIndex {
            do {
                recording.summary = try await LocalAIService().generateSummary(
                    transcription: transcription,
                    systemPrompt: appSettings.effectiveSummaryPrompt
                )
                markCompleted(summaryStepIndex)
            } catch {
                markFailed(summaryStepIndex, error.localizedDescription)
            }
        }

        if let actionStepIndex {
            do {
                recording.actionItems = try await LocalAIService().extractActionItems(
                    transcription: transcription,
                    systemPrompt: appSettings.effectiveActionItemsPrompt
                )
                markCompleted(actionStepIndex)
            } catch {
                markFailed(actionStepIndex, error.localizedDescription)
            }
        }

        if let tagsStepIndex {
            do {
                let result = try await LocalAIService().analyzeTags(
                    transcription: transcription,
                    systemPrompt: appSettings.effectiveTagsPrompt
                )
                recording.tags = result.tags
                recording.sentiment = result.sentiment
                markCompleted(tagsStepIndex)
            } catch {
                markFailed(tagsStepIndex, error.localizedDescription)
            }
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
        do {
            let insights = try await withPluginStepAdapter(stepIndex: firstNonNil(summaryStepIndex, actionStepIndex, tagsStepIndex)) {
                let stream = await self.localAIPluginService.analyzeTranscriptStream(
                    transcription,
                    outputLanguage: self.appSettings.outputLanguage
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
                // Final UI update + clear after generation completes
                await MainActor.run { self.appState.liveInferenceText = nil }
                
                // Decode the full finalized JSON text matching the old return type
                return try MLXInsightsService.decodeAndNormalize(fullJSON)
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
                    systemPrompt: appSettings.effectiveSummaryPrompt
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
                    systemPrompt: appSettings.effectiveActionItemsPrompt
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
                    systemPrompt: appSettings.effectiveTagsPrompt
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
            appState.processingSteps[stepIndex].name = "Analyzing transcript (Qwen3 4B local)"
        case .downloading(let progress, let stage):
            appState.processingSteps[stepIndex].progress = progress
            switch stage {
            case .whisperModel:
                appState.processingSteps[stepIndex].name = "Downloading WhisperKit model…"
            case .whisperModelLoading:
                appState.processingSteps[stepIndex].name = "Loading WhisperKit model…"
                appState.processingSteps[stepIndex].progress = nil // loading is indeterminate
            case .llmModel:
                appState.processingSteps[stepIndex].name = "Downloading Qwen model"
            case .speakerKitModel:
                appState.processingSteps[stepIndex].name = "Downloading SpeakerKit model"
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

    private func transcribeRecordingAudio(
        recording: Recording,
        stepIndex: Int
    ) async throws -> TranscriptionResult {
        if !recording.segmentAudioURLs.isEmpty {
            return try await transcribeSegmentedAudio(recording: recording, stepIndex: stepIndex)
        }
        return try await transcribeSingleAudioFile(
            recording.fileURL,
            stepIndex: stepIndex,
            segmentIndex: nil,
            segmentCount: nil
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
            return try await localTranscriptionService.transcribe(
                fileURL: url,
                language: appSettings.effectiveTranscriptionLanguage
            )
        case .localWhisper:
            let whisperConfig = WhisperRuntimeConfig(
                modelName: appSettings.whisperModelName,
                language: appSettings.transcriptionLanguage.isEmpty ? nil : appSettings.transcriptionLanguage,
                diarizationEnabled: appSettings.diarizationEnabled
            )
            return try await withPluginStepAdapter(stepIndex: stepIndex) {
                try await self.localAIPluginService.transcribe(
                    fileURL: url,
                    initialPrompt: self.appSettings.effectiveWhisperPrompt,
                    whisperConfig: whisperConfig
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

        // Skip segmentation for local transcription engines (they handle long files well)
        let segmentationEnabled = appSettings.effectiveTranscriptionEngine != .localWhisper
        let result = try await recordingFinalizer.finalize(
            rawURL: recording.fileURL,
            recording: recording,
            baseFolder: appSettings.effectiveRecordingFolderURL,
            segmentationEnabled: segmentationEnabled
        )

        recording.fileURL = result.masterAudioURL
        recording.finalizedAudioURL = result.masterAudioURL
        recording.segmentAudioURLs = result.segmentAudioURLs
        recording.metadataURL = result.metadataURL
        recording.finalizationWarnings = result.warnings

        if let attrs = try? FileManager.default.attributesOfItem(atPath: result.masterAudioURL.path),
           let size = attrs[.size] as? Int64
        {
            recording.fileSize = size
        }
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

    private static func generateRawCaptureURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dbrief-raw-\(UUID().uuidString).flac")
    }

    private static func dateOnlyString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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
            let audioURL = stem.appendingPathExtension("flac")
            guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }

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
            || integrations.notion.enabled
            || integrations.evernote.enabled
            || integrations.googleKeep.enabled
            || integrations.oneNote.enabled
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
