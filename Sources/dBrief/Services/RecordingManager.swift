import Foundation
import AppKit
import AVFoundation
import UserNotifications
import UniformTypeIdentifiers

@MainActor
@Observable
final class RecordingManager {
    private let appState: AppState
    private let appSettings: AppSettings
    private let audioCaptureManager = AudioCaptureManager()
    private let transcriptionService = TranscriptionService()
    private let localTranscriptionService = LocalTranscriptionService()
    private let localAIPluginService = LocalAIPluginService()
    var miniPlayer: FloatingMiniPlayerController?
    private let aiService = AIService()
    private let markdownGenerator = MarkdownGenerator()
    private let integrationDispatchService = IntegrationDispatchService()
    private let recordingFinalizer = RecordingFinalizer()

    init(appState: AppState, appSettings: AppSettings) {
        self.appState = appState
        self.appSettings = appSettings
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
                } catch {
                    appState.processingSteps[stepIndex].status = .failed(error.localizedDescription)
                }
            }
        }

        // Step 2: AI tasks (run sequentially to avoid TaskGroup @MainActor issues)
        if let transcription = recording.transcription {
            let aiEngine = appSettings.effectiveAIEngine
            let endpoint = appSettings.effectiveDefaultAIEndpoint
            let localAvailable = localAIAvailable

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
                    transcription: transcription.text,
                    localAvailable: localAvailable,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            case .qwenLocal:
                await runLocalQwenTasks(
                    transcription: transcription.text,
                    summaryStepIndex: summaryStepIndex,
                    actionStepIndex: actionStepIndex,
                    tagsStepIndex: tagsStepIndex,
                    recording: recording
                )
            case .remoteEndpoint:
                await runRemoteAITasks(
                    transcription: transcription.text,
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
            if let transcriptionText = recording.transcription?.text, !transcriptionText.isEmpty {
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
                case .localWhisper: Endpoint(name: "WhisperKit", baseURL: "", modelName: "whisper-small (CoreML)")
                case .remoteEndpoint: appSettings.effectiveDefaultTranscriptionEndpoint
                }
                let aiEndpoint: Endpoint? = switch appSettings.effectiveAIEngine {
                case .appleIntelligence: Endpoint(name: "Apple Intelligence", baseURL: "", modelName: "Apple Intelligence")
                case .qwenLocal: Endpoint(name: "Qwen 2.5 Local", baseURL: "", modelName: "Qwen2.5-7B-Instruct-4bit (MLX)")
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
            finalizedAudioURL: url
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
        case .qwenLocal: "Generating summary (Qwen 2.5 local)"
        case .remoteEndpoint: "Generating summary"
        }
    }

    private func labelForActionItems(engine: AppSettings.AIEngine) -> String {
        switch engine {
        case .appleIntelligence: "Extracting action items (Apple Intelligence)"
        case .qwenLocal: "Extracting action items (Qwen 2.5 local)"
        case .remoteEndpoint: "Extracting action items"
        }
    }

    private func labelForTags(engine: AppSettings.AIEngine) -> String {
        switch engine {
        case .appleIntelligence: "Analyzing tags (Apple Intelligence)"
        case .qwenLocal: "Analyzing tags & sentiment (Qwen 2.5 local)"
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
                try await self.localAIPluginService.analyzeTranscript(
                    transcription,
                    outputLanguage: self.appSettings.outputLanguage
                )
            }

            if let summaryStepIndex {
                recording.summary = insights.summary
                markCompleted(summaryStepIndex)
            }
            if !insights.titleConcept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let datePrefix = Self.dateOnlyString(recording.date)
                recording.generatedTitle = "\(datePrefix) - \(insights.titleConcept.trimmingCharacters(in: .whitespacesAndNewlines))"
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
        case .analyzing:
            appState.processingSteps[stepIndex].name = "Analyzing transcript (Qwen 2.5 local)"
        case .downloading(_, let stage):
            switch stage {
            case .whisperModel:
                appState.processingSteps[stepIndex].name = "Downloading WhisperKit model"
            case .llmModel:
                appState.processingSteps[stepIndex].name = "Downloading Qwen model"
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
            return try await withPluginStepAdapter(stepIndex: stepIndex) {
                try await self.localAIPluginService.transcribe(
                    fileURL: url,
                    initialPrompt: self.appSettings.effectiveWhisperPrompt
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

        let result = try await recordingFinalizer.finalize(
            rawURL: recording.fileURL,
            recording: recording,
            baseFolder: appSettings.effectiveRecordingFolderURL
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
                        text: segment.text
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
