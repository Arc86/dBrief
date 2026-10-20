import AppKit

enum AnnouncementPriority: Sendable {
    case normal
    case high
}

/// What VoiceOver says when recording or processing changes state, so a status
/// change that is only visual (the menu bar icon, a banner) is also spoken.
enum RecordingAnnouncement: Equatable, Sendable {
    case started
    case paused
    case resumed
    case stopped
    case failed
    case processingFinished(failedSteps: Int)
    case error(String)

    var text: String {
        switch self {
        case .started: String(localized: "Recording started")
        case .paused: String(localized: "Recording paused")
        case .resumed: String(localized: "Recording resumed")
        case .stopped: String(localized: "Recording stopped")
        case .failed: String(localized: "Recording failed")
        case .processingFinished(let failed) where failed == 0: String(localized: "Processing complete")
        case .processingFinished(let failed):
            String(AttributedString(localized: "Processing finished, ^[\(failed) step](inflect: true) failed").characters)
        case .error(let message): String(localized: "Error: \(message)")
        }
    }

    var priority: AnnouncementPriority {
        switch self {
        case .failed, .error: .high
        case .processingFinished(let failed): failed == 0 ? .normal : .high
        case .started, .paused, .resumed, .stopped: .normal
        }
    }
}

/// Posts VoiceOver announcements. The same message within a second is spoken
/// once, so a state change reported from two places (hotkey and panel) isn't
/// read twice.
@MainActor
final class AccessibilityAnnouncer {
    typealias Poster = @MainActor (String, AnnouncementPriority) -> Void

    static let shared = AccessibilityAnnouncer()
    static let repeatWindow: TimeInterval = 1

    private let post: Poster
    private let now: () -> Date
    private var last: (text: String, at: Date)?

    init(post: @escaping Poster = AccessibilityAnnouncer.postToVoiceOver, now: @escaping () -> Date = Date.init) {
        self.post = post
        self.now = now
    }

    func announce(_ event: RecordingAnnouncement) {
        announce(event.text, priority: event.priority)
    }

    func announce(_ text: String, priority: AnnouncementPriority = .normal) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let time = now()
        if let last, last.text == text, time.timeIntervalSince(last.at) < Self.repeatWindow { return }
        last = (text, time)
        post(text, priority)
    }

    /// AppKit's announcement request, which VoiceOver speaks without moving focus.
    static func postToVoiceOver(_ text: String, priority: AnnouncementPriority) {
        guard let app = NSApp else { return }
        let level: NSAccessibilityPriorityLevel = priority == .high ? .high : .medium
        NSAccessibility.post(element: app, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: level.rawValue])
    }
}
