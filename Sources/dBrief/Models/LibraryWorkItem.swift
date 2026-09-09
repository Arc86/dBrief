import Foundation

/// Work has its own identity and navigation target. A missing/future master
/// recording is never represented as a playable RecordingBrowserItem.
struct LibraryWorkItem: Codable, Identifiable, Sendable {
    enum Target: String, Codable, Sendable { case recovery, delivery, queue, capture }
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
