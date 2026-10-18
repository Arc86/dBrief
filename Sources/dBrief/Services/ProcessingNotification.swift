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
        let name = String(localized: "“\(title)”", comment: "A meeting title in quotation marks")
        switch outcome {
        case .processed(let analyzed):
            return .init(title: String(localized: "Recording processed"),
                         body: analyzed ? String(localized: "\(name) is transcribed and analyzed.")
                             : String(localized: "\(name) is transcribed."))
        case .finishedWithIssues(let steps):
            let first = steps.first ?? String(localized: "A step")
            let body = steps.count > 1
                ? String(AttributedString(localized:
                    "\(name): \(first) and ^[\(steps.count - 1) more step](inflect: true) didn't finish. Open it to retry.").characters)
                : String(localized: "\(name): \(first) didn't finish. Open it to retry.")
            return .init(title: String(localized: "Processing finished with issues"), body: body)
        case .failed(let stage):
            return .init(title: String(localized: "Processing didn't finish"),
                         body: String(localized: "\(name): \(stage) failed. Open it to retry."))
        case .reprocessed:
            return .init(title: String(localized: "Reprocessing finished"), body: String(localized: "\(name) has new results."))
        case .reprocessFailed:
            return .init(title: String(localized: "Reprocessing didn't finish"),
                         body: String(localized: "\(name): current results were kept. Open it to retry."))
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
