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
    /// Set to expand the menu panel's Queue & Recovery for this work item.
    var queueFocusRequest: UUID?
    /// Errors, warnings and results the user should see, newest first.
    var notices = NoticeList()

    func post(_ notice: AppNotice) { notices.post(notice) }

    func post(_ tone: AppNotice.Tone, _ message: String, source: AppNotice.Source,
              recordingURL: URL? = nil, actions: [NoticeAction] = []) {
        post(AppNotice(tone: tone, message: message, source: source, recordingURL: recordingURL, actions: actions))
    }

    /// Legacy single error. Setting it posts a `.general` notice; setting nil clears only
    /// those, never typed notices from other sources. Reading returns the newest error.
    var lastError: String? {
        get { notices.items.first { $0.tone == .error }?.message }
        set {
            if let newValue { post(.init(tone: .error, message: newValue, source: .general)) }
            else { notices.clear(source: .general) }
        }
    }
    /// Transient note shown during recording when dBrief auto-switches the input
    /// device or echo cancellation mid-recording (e.g. "Switched to MacBook Microphone").
    /// Auto-cleared a few seconds after it's set; nil when there's nothing to show.
    var recordingStatusNote: String? {
        didSet { if recordingStatusNote == nil { recordingStatusNoteIsProblem = false } }
    }
    /// The note is a problem to act on (silent or muted mic); shown in the warning tone.
    var recordingStatusNoteIsProblem = false
    /// Name of the microphone the current recording is capturing from. Can differ
    /// from the saved selection (a pinned device that disappeared falls back to
    /// the system default), so the recording UI shows this rather than the setting.
    var activeMicrophoneName: String?
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
    /// What the step does, so a failed brief can offer the matching fix.
    var kind: Kind = .other

    enum Kind: Equatable { case transcription, analysis, export, delivery, other }

    init(name: String, status: Status, progress: Double? = nil, detail: String? = nil, kind: Kind = .other) {
        self.name = name
        self.status = status
        self.progress = progress
        self.detail = detail
        self.kind = kind
    }

    enum Status {
        case pending
        case inProgress
        case completed
        /// Finished, with a note the user should see. Unlike `.failed`, it does
        /// not mark processing as unsuccessful or hold back integrations.
        case warning(String)
        case failed(String)
    }

    static func warnings(_ name: String, _ messages: [String]) -> ProcessingStep? {
        messages.isEmpty ? nil : ProcessingStep(name: name, status: .warning(messages.joined(separator: "\n")))
    }

    var warningMessage: String? {
        if case .warning(let message) = status { message } else { nil }
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
