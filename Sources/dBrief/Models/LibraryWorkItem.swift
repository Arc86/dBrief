import Foundation

/// Work has its own identity and navigation target. A missing/future master
/// recording is never represented as a playable RecordingBrowserItem.
struct LibraryWorkItem: Codable, Identifiable, Sendable {
    /// Title and status (including `RecoveryQueueEntry` statuses) are stored in the
    /// library database in English; these show them in the user's language. Other values (an attempt's own message) pass through.
    var displayTitle: String { Self.localizedStoredText(title) }
    var displayStatus: String { Self.localizedStoredText(status) }

    static func localizedStoredText(_ value: String) -> String {
        switch value {
        case "Interrupted recording": String(localized: "Interrupted recording")
        case "Interrupted capture": String(localized: "Interrupted capture")
        case "Recording unavailable": String(localized: "Recording unavailable")
        case "Queued": String(localized: "Queued")
        case "Queued recording unavailable": String(localized: "Queued recording unavailable")
        case "Reprocess queued": String(localized: "Reprocess queued")
        case "Reprocess needs attention": String(localized: "Reprocess needs attention")
        case "Couldn't save progress": String(localized: "Couldn't save progress")
        case "Audio finalization failed": String(localized: "Audio finalization failed")
        case "Transcription failed": String(localized: "Transcription failed")
        case "Speaker detection failed": String(localized: "Speaker detection failed")
        case "Speaker review needs attention": String(localized: "Speaker review needs attention")
        case "Analysis failed": String(localized: "Analysis failed")
        case "Markdown export failed": String(localized: "Markdown export failed")
        case "Integration review needed": String(localized: "Integration review needed")
        case "Processing failed": String(localized: "Processing failed")
        case "Stopped": String(localized: "Stopped")
        case "Speaker review needed": String(localized: "Speaker review needed")
        default: value
        }
    }

    enum Target: String, Codable, Sendable { case recovery, delivery, queue, capture, reprocess }
    let id: String
    let recoveryID: UUID
    let target: Target
    let title: String
    let audioURL: URL?
    let date: Date
    let status: String
    let failed: Bool
    let sourcePath: String?
    let associatedApp: String
}

/// Minimal cached facts; large frozen Markdown/transcript delivery bundles are
/// deliberately not copied into the disposable library database.
enum LibraryWorkSource: Codable, Sendable {
    case job(RecoveryQueueEntry.JobFacts)
    case delivery(RecoveryQueueEntry.DeliveryFacts)
    case capture(InterruptedSessionManifest)
    case queue(UUID)
    case schedule(QueueSchedule)
}

extension LibraryWorkItem {
    /// What the library needs from a pending reprocess attempt.
    struct ReprocessFacts: Sendable {
        let id: UUID
        let audioURL: URL
        let status: ReprocessingStore.Status
        let message: String?
        let updatedAt: Date
    }

    /// Pending reprocess attempts as library work, like the menu panel lists them:
    /// queued ones in Queued / Interrupted, stopped or failed ones in Needs Attention.
    static func reprocessing(_ attempts: [ReprocessFacts], view: LibrarySmartView, activeAttemptID: UUID?) -> [LibraryWorkItem] {
        guard view.includesRecoveryWork else { return [] }
        return attempts.filter { $0.id != activeAttemptID && $0.status != .completed }.compactMap { attempt in
            let waiting = attempt.status == .queued
            guard waiting == (view == .queuedInterrupted) else { return nil }
            let title = RecordingBrowserItem.displayTitle(forAudioName: attempt.audioURL.deletingPathExtension().lastPathComponent)
            return LibraryWorkItem(id: "reprocess:" + attempt.id.uuidString.lowercased(), recoveryID: attempt.id,
                target: .reprocess, title: title, audioURL: attempt.audioURL, date: attempt.updatedAt,
                status: waiting ? "Reprocess queued" : (attempt.message ?? "Reprocess needs attention"),
                failed: !waiting, sourcePath: nil, associatedApp: "")
        }
    }
}
