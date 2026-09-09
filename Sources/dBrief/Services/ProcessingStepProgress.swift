import Foundation
import dBriefWire

/// MainActor bridge for callbacks that may arrive after their backend has returned.
/// A job, step and invocation must all still own the UI when the callback executes.
/// Helper callers install `handler` in MLProgress for request-correlated delivery.
/// They must not feed this bridge from an unscoped channel subscription.
@MainActor
final class ProcessingStepProgress {
    private weak var appState: AppState?
    private let job: ProcessingJob
    private let stepIndex: Int
    private let stepID: UUID?
    private var active = true

    init(appState: AppState, job: ProcessingJob, stepIndex: Int) {
        self.appState = appState
        self.job = job
        self.stepIndex = stepIndex
        self.stepID = appState.processingSteps.indices.contains(stepIndex)
            ? appState.processingSteps[stepIndex].id : nil
    }

    var isCurrent: Bool {
        guard active, !Task.isCancelled, job.task?.isCancelled != true,
              let appState, appState.processingJob === job,
              appState.processingSteps.indices.contains(stepIndex),
              appState.processingSteps[stepIndex].id == stepID,
              case .inProgress = appState.processingSteps[stepIndex].status else { return false }
        return true
    }

    func invalidate() { active = false }

    func handler(parakeet: Bool = false) -> MLProgress.Sink {
        let context = PrivacyTrace.context
        return { state in
            Task { @MainActor in
                PrivacyTrace.$context.withValue(context) {
                    if parakeet { self.applyParakeetState(state) }
                    else { self.applyPluginState(state) }
                }
            }
        }
    }

    @discardableResult
    func update(_ body: (inout ProcessingStep, ProcessingJob) -> Void) -> Bool {
        guard isCurrent, let appState else { return false }
        body(&appState.processingSteps[stepIndex], job)
        return true
    }
}

extension ProcessingStepProgress {
    @discardableResult
    func applyParakeetState(_ state: LocalAIPluginState) -> Bool {
        update { step, job in
            switch state {
            case .idle:
                break
            case .transcribing:
                step.name = "Transcribing (Parakeet)"
                if job.transcriptionStartedAt == nil {
                    job.transcriptionStartedAt = Date()
                }
            case .newSegments:
                break // Parakeet doesn't produce live segments
            case .diarizing:
                step.name = "Identifying speakers"
            case .analyzing:
                break
            case .downloading(let progress, let stage):
                step.progress = progress
                switch stage {
                case .parakeetModel:
                    step.name = "Downloading Parakeet model…"
                case .parakeetModelLoading:
                    step.name = "Loading Parakeet model…"
                    step.progress = nil
                case .speakerKitModel:
                    step.name = "Downloading speaker model…"
                default:
                    break
                }
            }
        }
    }

    @discardableResult
    func applyPluginState(_ state: LocalAIPluginState) -> Bool {
        update { step, job in
            switch state {
            case .idle:
                break
            case .transcribing:
                step.name = "Transcribing (Local WhisperKit)"
                if job.transcriptionStartedAt == nil {
                    job.transcriptionStartedAt = Date()
                }
            case .newSegments(let segments):
                // Progressive segments belong to THIS job's "In Progress" view, not the shared
                // capture live-set (a new recording may be capturing concurrently).
                job.progressiveSegments.append(contentsOf: segments)
                // First streamed segment implies transcription proper is under way — used by
                // the ETA ticker to switch to true segment-coverage progress.
                if job.transcriptionStartedAt == nil {
                    job.transcriptionStartedAt = Date()
                }
                return // don't update step name
            case .diarizing:
                step.name = "Identifying speakers"
            case .analyzing:
                step.name = "Analyzing transcript (Gemma 4 E4B local)"
            case .downloading(let progress, let stage):
                step.progress = progress
                switch stage {
                case .whisperModel:
                    step.name = "Downloading WhisperKit model…"
                case .whisperModelLoading:
                    step.name = "Loading WhisperKit model…"
                    step.progress = nil // loading is indeterminate
                case .llmModel:
                    step.name = "Downloading Gemma model"
                case .speakerKitModel:
                    step.name = "Downloading SpeakerKit model"
                case .parakeetModel:
                    step.name = "Downloading Parakeet model…"
                case .parakeetModelLoading:
                    step.name = "Loading Parakeet model…"
                    step.progress = nil
                case .ttsModel:
                    step.name = "Downloading TTS model…"
                case .ttsModelLoading:
                    step.name = "Loading TTS model…"
                    step.progress = nil
                case .kokoroTTSModel:
                    step.name = "Downloading Kokoro voice model…"
                case .kokoroTTSModelLoading:
                    step.name = "Loading Kokoro voice model…"
                    step.progress = nil
                }
            }
        }
    }
}
