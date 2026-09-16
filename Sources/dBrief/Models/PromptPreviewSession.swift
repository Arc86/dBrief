import Foundation
import Observation
import dBriefWire

@MainActor @Observable
final class PromptPreviewSession {
    private(set) var result: PromptPreviewOutput?
    private(set) var resultRequest: PromptPreviewRequest?
    private(set) var progress: PromptGenerationProgress?
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    let voice = VoicePreviewPlayer()
    @ObservationIgnored private var task: Task<PromptPreviewOutput, Error>?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func start(_ request: PromptPreviewRequest, using service: any PromptPreviewing) {
        cancel()
        launchTask = Task {
            guard !Task.isCancelled else { return }
            await run(request, using: service)
        }
    }
    func run(_ request: PromptPreviewRequest, using service: any PromptPreviewing) async {
        guard !Task.isCancelled else { return }
        cancelGeneration()
        let id = UUID()
        generation = id
        isRunning = true
        errorMessage = nil
        result = nil
        resultRequest = nil
        progress = .initial(for: request.configuration)
        let sink: MLProgress.Sink = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id, self.isRunning,
                      let progress = PromptGenerationProgress.from(state) else { return }
                self.progress = progress
            }
        }
        let task = Task {
            try await MLProgress.$sink.withValue(sink) { try await service.run(request) }
        }
        self.task = task
        defer { if generation == id { self.task = nil; isRunning = false; progress = nil } }
        do {
            let output = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == id, !task.isCancelled, !Task.isCancelled else { return }
            result = output
            resultRequest = request
        } catch {
            if generation == id, !task.isCancelled, !Task.isCancelled {
                if let error = error as? PromptPreviewError, error == .missingInsights || error == .emptyTranscript || error == .contextLimit {
                    errorMessage = error.localizedDescription
                } else if case .analysisFailure(let safeText) = error as? PromptPreviewError {
                    errorMessage = safeText
                } else if error is PromptAIError { errorMessage = error.localizedDescription }
                else { errorMessage = SettingsErrorSanitizer.details(for: error.localizedDescription) }
            }
        }
    }
    func cancel() {
        launchTask?.cancel()
        launchTask = nil
        cancelGeneration()
    }
    private func cancelGeneration() {
        generation = UUID()
        task?.cancel()
        task = nil
        isRunning = false
        progress = nil
        voice.stop()
    }
}
