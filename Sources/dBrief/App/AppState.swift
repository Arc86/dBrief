import Foundation
import dBriefWire

@MainActor
@Observable
final class AppState {
    enum RecordingState: Equatable {
        case idle
        case recording
        case paused
        case processing
    }

    var recordingState: RecordingState = .idle
    var recordingDuration: TimeInterval = 0
    var peakLevel: Float = 0
    var currentRecording: Recording?
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
    var isProcessing: Bool { recordingState == .processing }
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
