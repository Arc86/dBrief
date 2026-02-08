import Foundation
import AppKit
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
    var miniPlayer: FloatingMiniPlayerController?
    private let aiService = AIService()
    private let markdownGenerator = MarkdownGenerator()

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
        let fileName = Self.generateFileName()
        let fileURL = appSettings.recordingFolderURL.appendingPathComponent(fileName)

        try FileManager.default.createDirectory(
            at: appSettings.recordingFolderURL,
            withIntermediateDirectories: true
        )

        let recording = Recording(
            fileURL: fileURL,
            associatedApp: associatedApp
        )
        appState.currentRecording = recording

        try await audioCaptureManager.startRecording(
            to: fileURL,
            sampleRate: appSettings.audioSampleRate,
            bitRate: appSettings.audioBitRate
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
            // Update to actual file URL (may be .wav if AAC failed)
            if let actualURL, actualURL != recording.fileURL {
                recording.fileURL = actualURL
            }
            recording.duration = audioCaptureManager.duration
            if let attrs = try? FileManager.default.attributesOfItem(atPath: recording.fileURL.path),
               let size = attrs[.size] as? Int64
            {
                recording.fileSize = size
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
        guard let recording = appState.currentRecording else { return }
        appState.recordingState = .processing
        appState.showPostRecordingSheet = false
        appState.processingSteps = []

        // Step 1: Transcription
        if transcribe {
            let stepIndex = appState.processingSteps.count
            let stepName = appSettings.useBuiltInTranscription ? "Transcribing (Apple Speech)" : "Transcribing audio"
            appState.processingSteps.append(ProcessingStep(name: stepName, status: .inProgress))

            if appSettings.useBuiltInTranscription {
                do {
                    let result = try await localTranscriptionService.transcribe(
                        fileURL: recording.fileURL,
                        language: appSettings.transcriptionLanguage
                    )
                    recording.transcription = result
                    appState.processingSteps[stepIndex].status = .completed
                } catch {
                    appState.processingSteps[stepIndex].status = .failed(error.localizedDescription)
                }
            } else if let endpoint = appSettings.defaultTranscriptionEndpoint {
                do {
                    let result = try await transcriptionService.transcribe(
                        fileURL: recording.fileURL,
                        endpoint: endpoint,
                        language: appSettings.transcriptionLanguage,
                        initialPrompt: appSettings.whisperPrompt
                    )
                    recording.transcription = result
                    appState.processingSteps[stepIndex].status = .completed
                } catch {
                    appState.processingSteps[stepIndex].status = .failed(error.localizedDescription)
                }
            } else {
                appState.processingSteps[stepIndex].status = .failed("No transcription endpoint configured")
            }
        }

        // Step 2: AI tasks (run sequentially to avoid TaskGroup @MainActor issues)
        if let transcription = recording.transcription {
            let useLocal = appSettings.useBuiltInAI
            let endpoint = appSettings.defaultAIEndpoint

            if summary {
                let stepIndex = appState.processingSteps.count
                let label = useLocal ? "Generating summary (Apple Intelligence)" : "Generating summary"
                appState.processingSteps.append(ProcessingStep(name: label, status: .inProgress))
                do {
                    let result: String
                    #if canImport(FoundationModels)
                    if useLocal, #available(macOS 26, *) {
                        result = try await LocalAIService().generateSummary(
                            transcription: transcription.text,
                            systemPrompt: appSettings.summaryPrompt
                        )
                    } else if let endpoint {
                        result = try await aiService.generateSummary(
                            transcription: transcription.text,
                            endpoint: endpoint,
                            systemPrompt: appSettings.summaryPrompt
                        )
                    } else {
                        throw AIServiceError.invalidEndpoint
                    }
                    #else
                    if let endpoint {
                        result = try await aiService.generateSummary(
                            transcription: transcription.text,
                            endpoint: endpoint,
                            systemPrompt: appSettings.summaryPrompt
                        )
                    } else {
                        throw AIServiceError.invalidEndpoint
                    }
                    #endif
                    recording.summary = result
                    appState.processingSteps[stepIndex].status = .completed
                } catch {
                    appState.processingSteps[stepIndex].status = .failed(error.localizedDescription)
                }
            }

            if actionItems {
                let stepIndex = appState.processingSteps.count
                let label = useLocal ? "Extracting action items (Apple Intelligence)" : "Extracting action items"
                appState.processingSteps.append(ProcessingStep(name: label, status: .inProgress))
                do {
                    let result: [String]
                    #if canImport(FoundationModels)
                    if useLocal, #available(macOS 26, *) {
                        result = try await LocalAIService().extractActionItems(
                            transcription: transcription.text,
                            systemPrompt: appSettings.actionItemsPrompt
                        )
                    } else if let endpoint {
                        result = try await aiService.extractActionItems(
                            transcription: transcription.text,
                            endpoint: endpoint,
                            systemPrompt: appSettings.actionItemsPrompt
                        )
                    } else {
                        throw AIServiceError.invalidEndpoint
                    }
                    #else
                    if let endpoint {
                        result = try await aiService.extractActionItems(
                            transcription: transcription.text,
                            endpoint: endpoint,
                            systemPrompt: appSettings.actionItemsPrompt
                        )
                    } else {
                        throw AIServiceError.invalidEndpoint
                    }
                    #endif
                    recording.actionItems = result
                    appState.processingSteps[stepIndex].status = .completed
                } catch {
                    appState.processingSteps[stepIndex].status = .failed(error.localizedDescription)
                }
            }

            if tags {
                let stepIndex = appState.processingSteps.count
                let label = useLocal ? "Analyzing tags (Apple Intelligence)" : "Analyzing tags & sentiment"
                appState.processingSteps.append(ProcessingStep(name: label, status: .inProgress))
                do {
                    #if canImport(FoundationModels)
                    if useLocal, #available(macOS 26, *) {
                        let result = try await LocalAIService().analyzeTags(
                            transcription: transcription.text,
                            systemPrompt: appSettings.tagsPrompt
                        )
                        recording.tags = result.tags
                        recording.sentiment = result.sentiment
                    } else if let endpoint {
                        let result = try await aiService.analyzeTags(
                            transcription: transcription.text,
                            endpoint: endpoint,
                            systemPrompt: appSettings.tagsPrompt
                        )
                        recording.tags = result.tags
                        recording.sentiment = result.sentiment
                    } else {
                        throw AIServiceError.invalidEndpoint
                    }
                    #else
                    if let endpoint {
                        let result = try await aiService.analyzeTags(
                            transcription: transcription.text,
                            endpoint: endpoint,
                            systemPrompt: appSettings.tagsPrompt
                        )
                        recording.tags = result.tags
                        recording.sentiment = result.sentiment
                    } else {
                        throw AIServiceError.invalidEndpoint
                    }
                    #endif
                    appState.processingSteps[stepIndex].status = .completed
                } catch {
                    appState.processingSteps[stepIndex].status = .failed(error.localizedDescription)
                }
            }
        }

        // Step 3: Generate Markdown
        if transcribe || summary || actionItems || tags {
            let stepIndex = appState.processingSteps.count
            appState.processingSteps.append(ProcessingStep(name: "Writing Markdown", status: .inProgress))

            do {
                let outputFolder = resolveMarkdownOutputFolder(for: recording)
                try markdownGenerator.generate(
                    recording: recording,
                    outputFolder: outputFolder,
                    transcriptionEndpoint: appSettings.defaultTranscriptionEndpoint,
                    aiEndpoint: appSettings.defaultAIEndpoint
                )
                appState.processingSteps[stepIndex].status = .completed
            } catch {
                appState.processingSteps[stepIndex].status = .failed(error.localizedDescription)
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .wav, .mp3, .aiff]
        panel.message = "Choose an audio file to transcribe"

        let response = panel.runModal()
        NSApp.setActivationPolicy(.accessory)

        guard response == .OK, let url = panel.url else { return }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let recording = Recording(fileURL: url, fileSize: size)
        appState.currentRecording = recording
        appState.showPostRecordingSheet = true
    }

    func skipProcessing() {
        appState.showPostRecordingSheet = false
        appState.recordingState = .idle
    }

    func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Private

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

    private static func generateFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return "VoiceRecording_\(formatter.string(from: Date())).m4a"
    }

    private func resolveMarkdownOutputFolder(for recording: Recording) -> URL {
        if appSettings.obsidianEnabled,
           let obsidianFolder = appSettings.obsidianFolderURL(
            relativePath: recording.obsidianFolderRelativePath ?? appSettings.obsidianDefaultFolderRelativePath
           ) {
            return obsidianFolder
        }
        return appSettings.transcriptionFolderURL
    }
}
