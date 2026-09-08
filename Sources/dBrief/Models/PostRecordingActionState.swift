import Foundation
import Observation

/// One owner for post-recording work across SwiftUI refreshes and actor suspension.
@MainActor
@Observable
final class PostRecordingActionState {
    enum Action {
        case process, queue, skip, delete

        var title: String {
            switch self {
            case .process: "Preparing processing…"
            case .queue, .skip: "Saving recording…"
            case .delete: "Deleting recording…"
            }
        }
    }

    private(set) var recordingID: UUID?
    private(set) var token: UUID?
    private(set) var action: Action?
    private(set) var progress: Double?
    private(set) var error: String?
    var isBusy: Bool { token != nil }

    func begin(recordingID: UUID, action: Action) -> UUID? {
        guard !isBusy else { return nil }
        let token = UUID()
        self.recordingID = recordingID
        self.token = token
        self.action = action
        progress = nil
        error = nil
        return token
    }

    func updateProgress(_ value: Double, token: UUID) {
        guard self.token == token, value.isFinite else { return }
        progress = max(progress ?? 0, min(1, max(0, value)))
    }

    func finish(token: UUID, error: String? = nil) {
        guard self.token == token else { return }
        self.token = nil
        action = nil
        progress = nil
        self.error = error
    }
}
