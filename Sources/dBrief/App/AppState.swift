import Foundation
import dBriefWire

@MainActor
@Observable
final class AppState {
    /// Capture-only state machine. Processing is tracked separately via `processingJob`
    /// so a new recording can start (capture `.idle`) while a previous recording is still
    /// being processed in the background.
    enum RecordingState: Equatable {
        case idle
        case recording
        case paused
    }

    var recordingState: RecordingState = .idle
    var recordingDuration: TimeInterval = 0
    var peakLevel: Float = 0
    /// The recording currently being **captured** (or awaiting the post-recording sheet).
    /// Distinct from `processingJob.recording` — a new capture may overwrite this slot
    /// while a prior recording is still processing.
    var currentRecording: Recording?
    /// The single in-flight background processing job, or nil when none is running.
    /// Non-nil also while a job is paused for confirm-first speaker review.
    var processingJob: ProcessingJob?
    /// The recording that `processingSteps` / `liveInferenceText` describe. Set when a job
    /// starts and kept after it finishes (until the next job) so the results/completion UI
    /// targets the processed recording, not the (possibly newer) capture `currentRecording`.
    var processingRecording: Recording?
    var recentRecordings: [Recording] = []
    /// Non-nil while a recording is paused for confirm-first speaker review.
    var pendingSpeakerReview: SpeakerReviewSession?
    /// Bumped when a confirm-first re-diarize review commits, so an open
    /// transcript viewer reloads the updated transcript (and offers reanalysis).
    var speakerReviewCommit: SpeakerReviewCommit?
    /// Audio file URL the transcript browser should select when it opens
    /// (deep-link from the menu-bar history or results view).
    var pendingTranscriptSelectionURL: URL?

    var showPostRecordingSheet = false
    var showCallDetectedPopup = false {
        didSet {
            NotificationCenter.default.post(name: .callDetectedPopupChanged, object: showCallDetectedPopup)
        }
    }
    var detectedCallApp: String?
    var detectedCallAppBundleId: String?

    /// Bundle id of the call app that started the current recording, or `nil` for a
    /// manually started recording. Drives the `.callInitiatedOnly` stop-on-call-end scope.
    var callRecordingBundleId: String?
    /// Display name of the ended call, shown in the "call ended — stop recording?" prompt.
    var callEndedApp: String?
    var showCallEndedPopup = false {
        didSet {
            NotificationCenter.default.post(name: .callEndedPopupChanged, object: showCallEndedPopup)
        }
    }

    var processingSteps: [ProcessingStep] = []
    var liveInferenceText: String?
    var liveTranscriptSegments: [LiveTranscriptSegment] = []
    /// In-progress (volatile) partial text per live channel during real-time transcription.
    var liveVolatileMic: String = ""
    var liveVolatileSystem: String = ""
    /// True while real-time transcription is running during an active recording.
    var isLiveTranscribing: Bool = false
    /// Human-readable live-transcription status (e.g. "Preparing language…"), shown in
    /// the live transcript waiting state. Empty once segments start arriving.
    var liveStatusMessage: String = ""
    /// When set, the transcript browser should select the in-progress live recording on open.
    var pendingLiveTranscriptSelection: Bool = false
    var lastError: String?
    /// Transient note shown during recording when dBrief auto-switches the input
    /// device or echo cancellation mid-recording (e.g. "Switched to MacBook Microphone").
    /// Auto-cleared a few seconds after it's set; nil when there's nothing to show.
    var recordingStatusNote: String?
    var queuedCount: Int = 0
    var memoryPressureLevel: MemoryPressureLevel = .normal
    var preflightWarning: PreflightWarning?

    var isRecording: Bool { recordingState == .recording }
    var isPaused: Bool { recordingState == .paused }
    /// True while a background processing job is running (independent of capture state).
    var isProcessing: Bool { processingJob != nil }
    /// True when **capture** is idle — drives the Record button/hotkey. A background
    /// processing job may still be running.
    var isIdle: Bool { recordingState == .idle }
    var hasProcessingResults: Bool { !processingSteps.isEmpty }

    func recording(for id: UUID) -> Recording? {
        recentRecordings.first { $0.id == id }
    }
}

struct ProcessingStep: Identifiable {
    let id = UUID()
    var name: String
    var status: Status
    var progress: Double?   // 0.0–1.0 for determinate, nil for indeterminate spinner
    /// Optional secondary line under the step (e.g. "about 2 min left" during
    /// transcription). Nil when there's nothing to show.
    var detail: String?

    enum Status {
        case pending
        case inProgress
        case completed
        case failed(String)
    }
}

// MARK: - Memory pressure

enum MemoryPressureLevel: Equatable {
    case normal
    case warning
    case critical
}

struct PreflightWarning: Equatable {
    let modelName: String
    let requiredGB: Double
    let availableGB: Double
    let hasRemoteEndpoint: Bool
}
