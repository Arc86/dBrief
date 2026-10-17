import Foundation
import UserNotifications
import AppKit

/// What a processing notification says. Sentence-case titles, the meeting's display
/// title, and a next step when something didn't finish.
enum ProcessingNotification {
    enum Outcome: Equatable {
        case processed(analyzed: Bool)
        case finishedWithIssues(failedSteps: [String])
        /// `stage` is a step-like label, e.g. "Transcription".
        case failed(stage: String)
        case reprocessed
        case reprocessFailed
    }

    struct Content: Equatable {
        let title: String
        let body: String
    }

    static let recordingPathKey = "recordingPath"

    static func content(_ outcome: Outcome, title: String) -> Content {
        let name = "“\(title)”"
        switch outcome {
        case .processed(let analyzed):
            return .init(title: "Recording processed",
                         body: "\(name) is \(analyzed ? "transcribed and analyzed" : "transcribed").")
        case .finishedWithIssues(let steps):
            let first = steps.first ?? "A step"
            let more = steps.count > 1 ? " and \(steps.count - 1) more step\(steps.count == 2 ? "" : "s")" : ""
            return .init(title: "Processing finished with issues",
                         body: "\(name): \(first)\(more) didn't finish. Open it to retry.")
        case .failed(let stage):
            return .init(title: "Processing didn't finish", body: "\(name): \(stage.lowercased()) failed. Open it to retry.")
        case .reprocessed:
            return .init(title: "Reprocessing finished", body: "\(name) has new results.")
        case .reprocessFailed:
            return .init(title: "Reprocessing didn't finish", body: "\(name): current results were kept. Open it to retry.")
        }
    }

    /// Posts `content`; clicking it opens `recordingURL` in the library.
    static func post(_ content: Content, recordingURL: URL?) {
        guard Bundle.main.bundleIdentifier != nil else { return } // Not in unbundled test hosts.
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.sound = .default
        if let recordingURL { notification.userInfo = [recordingPathKey: recordingURL.path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                     content: notification, trigger: nil))
    }
}

/// Shows notifications while dBrief is frontmost and opens the recording a notification
/// is about when it is clicked.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo[ProcessingNotification.recordingPathKey] as? String
        Task { @MainActor in
            if let path { AppContext.shared.appState.pendingTranscriptSelectionURL = URL(fileURLWithPath: path) }
            StatusItemControls.shared.openWindow("transcript")
        }
        completionHandler()
    }
}
