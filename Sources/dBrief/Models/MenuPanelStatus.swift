import Foundation

/// What the menu panel header says. Capture always wins (a recording can start
/// while an earlier job processes); the review form wins over background work.
enum MenuPanelStatus: Equatable {
    case ready, recording, paused, processing, recordingCompleted, briefReady

    enum Tone: Equatable { case success, danger, warning, accent }

    static func resolve(isRecording: Bool, isPaused: Bool, isProcessing: Bool, showsPostRecording: Bool, hasResults: Bool) -> MenuPanelStatus {
        if isRecording { return .recording }
        if isPaused { return .paused }
        if showsPostRecording { return .recordingCompleted }
        if isProcessing { return .processing }
        if hasResults { return .briefReady }
        return .ready
    }

    var label: String {
        switch self {
        case .ready: "Ready"
        case .recording: "Recording"
        case .paused: "Paused"
        case .processing: "Processing"
        case .recordingCompleted: "Recording completed"
        case .briefReady: "Brief ready"
        }
    }

    var tone: Tone {
        switch self {
        case .ready, .recordingCompleted, .briefReady: .success
        case .recording: .danger
        case .paused: .warning
        case .processing: .accent
        }
    }
}

enum MenuPanelProgress {
    static func doneLabel(_ steps: [ProcessingStep]) -> String? {
        guard !steps.isEmpty else { return nil }
        let done = steps.filter { if case .completed = $0.status { true } else { false } }.count
        return "\(done) of \(steps.count) done"
    }

    /// Tasks that will actually run: AI tasks need a transcript and AI processing on.
    static func selectedTaskCount(transcribe: Bool, summary: Bool, actionItems: Bool, tags: Bool, aiEnabled: Bool) -> Int {
        guard transcribe else { return 0 }
        guard aiEnabled else { return 1 }
        return 1 + [summary, actionItems, tags].filter { $0 }.count
    }

    static func briefContents(summary: Bool, actions: Bool, tags: Bool, notes: Bool) -> String? {
        let parts = [(summary, "Summary"), (actions, "Actions"), (tags, "Tags"), (notes, "Notes")]
            .filter { $0.0 }.map { $0.1 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
