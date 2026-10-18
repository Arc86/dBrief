import Foundation

/// What the menu panel header says. Capture always wins (a recording can start
/// while an earlier job processes); the review form wins over background work.
enum MenuPanelStatus: Equatable {
    case ready, recording, paused, processing, recordingCompleted, briefReady, finishedWithIssues

    enum Tone: Equatable { case success, danger, warning, accent }

    static func resolve(isRecording: Bool, isPaused: Bool, isProcessing: Bool, showsPostRecording: Bool, hasResults: Bool,
                        hasFailures: Bool = false) -> MenuPanelStatus {
        if isRecording { return .recording }
        if isPaused { return .paused }
        if showsPostRecording { return .recordingCompleted }
        if isProcessing { return .processing }
        if hasResults { return hasFailures ? .finishedWithIssues : .briefReady }
        return .ready
    }

    var label: String {
        switch self {
        case .ready: String(localized: "Ready")
        case .recording: String(localized: "Recording")
        case .paused: String(localized: "Paused")
        case .processing: String(localized: "Processing")
        case .recordingCompleted: String(localized: "Recording completed")
        case .briefReady: String(localized: "Brief ready")
        case .finishedWithIssues: String(localized: "Finished with issues")
        }
    }

    var tone: Tone {
        switch self {
        case .ready, .recordingCompleted, .briefReady: .success
        case .recording: .danger
        case .paused, .finishedWithIssues: .warning
        case .processing: .accent
        }
    }
}

enum MenuPanelProgress {
    static func doneLabel(_ steps: [ProcessingStep]) -> String? {
        guard !steps.isEmpty else { return nil }
        let done = steps.filter { if case .completed = $0.status { true } else { false } }.count
        return String(localized: "\(done) of \(steps.count) done")
    }

    /// Whether the brief should offer "More details": anything beyond the
    /// four-line preview, judged at roughly 42 characters per line of the panel.
    static func offersMoreDetails(summary: String?, transcriptFallback: Bool, actionCount: Int, tagCount: Int, hasSentiment: Bool) -> Bool {
        if transcriptFallback || actionCount > 0 || tagCount > 0 || hasSentiment { return true }
        guard let summary else { return false }
        let lines = summary.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int((Double($1.count) / 42).rounded(.up))) }
        return lines > 4
    }

    static func processingHeading(title: String?, complete: Bool) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return complete ? String(localized: "Processing complete") : String(localized: "Processing recording")
        }
        return complete ? String(localized: "Processed “\(title)”") : String(localized: "Processing “\(title)”")
    }

    /// During record-while-processing two Stop buttons are on screen; name the job's one.
    static func stopProcessingTitle(isCapturing: Bool) -> String {
        isCapturing ? String(localized: "Stop processing") : String(localized: "Stop")
    }

    /// A deferred profile switch happens on its own when the current job ends, so
    /// its notice and opt-out stay visible instead of inside Processing settings.
    static func profileNoticeOnSurface(isDeferred: Bool) -> Bool { isDeferred }

    /// Tasks that will actually run: AI tasks need a transcript and AI processing on.
    static func selectedTaskCount(transcribe: Bool, summary: Bool, actionItems: Bool, tags: Bool, aiEnabled: Bool) -> Int {
        guard transcribe else { return 0 }
        guard aiEnabled else { return 1 }
        return 1 + [summary, actionItems, tags].filter { $0 }.count
    }

    static func briefContents(summary: Bool, actions: Bool, tags: Bool, notes: Bool) -> String? {
        let parts = [(summary, String(localized: "Summary")), (actions, String(localized: "Actions")),
                     (tags, String(localized: "Tags")), (notes, String(localized: "Notes"))]
            .filter { $0.0 }.map { $0.1 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The fixes a finished brief offers for its failed steps.
enum BriefRecovery: Equatable {
    case reanalyze, integrations

    static func hasFailures(_ steps: [ProcessingStep]) -> Bool {
        steps.contains { if case .failed = $0.status { true } else { false } }
    }

    static func actions(for steps: [ProcessingStep]) -> [BriefRecovery] {
        let failed = steps.filter { if case .failed = $0.status { true } else { false } }.map(\.kind)
        return (failed.contains(.analysis) ? [.reanalyze] : []) + (failed.contains(.delivery) ? [.integrations] : [])
    }
}
