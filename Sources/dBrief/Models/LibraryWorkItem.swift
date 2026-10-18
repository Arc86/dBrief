import Foundation

/// Work has its own identity and navigation target. A missing/future master
/// recording is never represented as a playable RecordingBrowserItem.
struct LibraryWorkItem: Codable, Identifiable, Sendable {
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
