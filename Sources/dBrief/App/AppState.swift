import Foundation

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

    var showPostRecordingSheet = false
    var showCallDetectedPopup = false {
        didSet {
            NotificationCenter.default.post(name: .callDetectedPopupChanged, object: showCallDetectedPopup)
        }
    }
    var detectedCallApp: String?
    var detectedCallAppBundleId: String?

    var processingSteps: [ProcessingStep] = []
    var lastError: String?

    var isRecording: Bool { recordingState == .recording }
    var isPaused: Bool { recordingState == .paused }
    var isProcessing: Bool { recordingState == .processing }
    var isIdle: Bool { recordingState == .idle }
    var hasProcessingResults: Bool { !processingSteps.isEmpty }
}

struct ProcessingStep: Identifiable {
    let id = UUID()
    var name: String
    var status: Status

    enum Status {
        case pending
        case inProgress
        case completed
        case failed(String)
    }
}
