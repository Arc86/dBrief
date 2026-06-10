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
    /// When set, the transcript browser should select the in-progress live recording on open.
    var pendingLiveTranscriptSelection: Bool = false
    var lastError: String?
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
