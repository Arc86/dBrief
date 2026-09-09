import Foundation

/// Owns mutations of the current capture/review slot without taking ownership of
/// an independently running processing job. Recheck at every async handoff.
@MainActor
final class RecordingReviewSlot {
    struct ImportSnapshot {
        let recording: Recording?
        let showingReview: Bool
    }
    enum Failure: LocalizedError {
        case busy
        var errorDescription: String? {
            "Wait for recording, saving or cleanup to finish before importing audio."
        }
    }
    private let appState: AppState
    private let action: PostRecordingActionState
    private let captureBusy: () -> Bool
    private let maintenance: () -> Bool

    init(appState: AppState, action: PostRecordingActionState,
         captureBusy: @escaping () -> Bool, maintenance: @escaping () -> Bool) {
        self.appState = appState
        self.action = action
        self.captureBusy = captureBusy
        self.maintenance = maintenance
    }

    var canImport: Bool {
        !captureBusy() && !action.isBusy && !maintenance() && appState.recordingState == .idle
    }

    func snapshotForImport() -> ImportSnapshot? {
        guard canImport else { return nil }
        return .init(recording: appState.currentRecording, showingReview: appState.showPostRecordingSheet)
    }

    func canAcceptImport(_ snapshot: ImportSnapshot) -> Bool {
        canImport && appState.currentRecording === snapshot.recording
            && appState.showPostRecordingSheet == snapshot.showingReview
    }

    @discardableResult
    func acceptImport(_ recording: Recording, replacing snapshot: ImportSnapshot) -> Bool {
        guard canAcceptImport(snapshot) else { return false }
        appState.currentRecording = recording
        appState.showPostRecordingSheet = true
        return true
    }

    func ownsAction(for recording: Recording, token: UUID) -> Bool {
        isCurrentReview(recording) && action.recordingID == recording.id && action.token == token
    }

    @discardableResult
    func dismiss(for recording: Recording, actionToken: UUID? = nil) -> Bool {
        guard isCurrentReview(recording) else { return false }
        if let actionToken, !ownsAction(for: recording, token: actionToken) { return false }
        appState.showPostRecordingSheet = false
        return true
    }

    private func isCurrentReview(_ recording: Recording) -> Bool {
        !captureBusy() && appState.recordingState == .idle && appState.showPostRecordingSheet
            && appState.currentRecording === recording
    }
}
