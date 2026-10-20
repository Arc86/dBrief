import Foundation

/// Actions on an existing recording whose availability depends on saved and running work.
enum RecordingAction: CaseIterable, Sendable {
    case reprocess, linkCalendar, delete
    /// Summary, action items, tags, speakers and the spoken summary.
    case edit
}

/// What saved or running work currently owns one recording.
struct RecordingOwnership: Equatable, Sendable {
    var queueMarkerID: UUID?
    /// A saved processing job that is not finished (`PersistedProcessingJob.isFinished`) or dismissed.
    var unfinishedJobID: UUID?
    var pendingAttemptID: UUID?
    var isActiveJob = false
    /// The recording being captured, or the one open in the post-recording review form.
    var isCaptureOrReview = false
    var isHeldForSpeakerReview = false
}

/// App-wide state that is not about one recording.
struct AppActivity: Equatable, Sendable {
    /// Short operations that briefly hold the shared queue and recovery records.
    enum Operation: CaseIterable, Equatable, Sendable {
        case saving, cleanup, stopping, integrations, queueEdit
    }
    var recoveryReady = true
    var operation: Operation?
    /// Title of the job running for any recording.
    var activeJobTitle: String?
    var captureOrReviewOpen = false
    var unreadableRecords = false
}

/// Where the user can resolve a block.
enum RecordingResolution: Hashable, Sendable {
    case showInQueue(UUID)
    case discardRunAndRetranscribe(UUID)
}

/// Why an action on a recording is unavailable right now. One message, used by the
/// disabled control's help and by the error the manager throws on a stale click.
enum RecordingBlock: Equatable, Sendable {
    case startingUp
    case processingNow
    case underReview
    case speakerReview
    case queued(UUID)
    case unfinishedRun(UUID)
    case pendingReprocess(UUID)
    case otherJobRunning(String)
    case recordingInProgress
    case unreadableRecords
    case busy(AppActivity.Operation)

    var message: String {
        switch self {
        case .startingUp: String(localized: "dBrief is still checking saved work. Try again in a moment.")
        case .processingNow: String(localized: "This recording is processing now. Wait for it to finish, or stop it.")
        case .underReview: String(localized: "This recording is open in the review form. Process, queue or delete it there first.")
        case .speakerReview: String(localized: "This recording is waiting for you to confirm its speakers.")
        case .queued: String(localized: "This recording is waiting in the queue. Process it or remove it from Queue & Recovery first.")
        case .unfinishedRun: String(localized: "This recording has an unfinished processing run in Queue & Recovery. Resume it, or discard it to start again.")
        case .pendingReprocess: String(localized: "This recording has an unfinished reprocess in Queue & Recovery. Resume or discard it first.")
        case .otherJobRunning(let title): String(localized: "Wait for “\(title)” to finish processing before deleting a recording.")
        case .recordingInProgress: String(localized: "Finish the current recording and its review before deleting a recording.")
        case .unreadableRecords: String(localized: "Some saved processing records can't be read. Move them aside in Queue & Recovery first.")
        case .busy(.saving): String(localized: "dBrief is saving a recording. Try again in a moment.")
        case .busy(.cleanup): String(localized: "Cleanup or recovery is running. Try again when it finishes.")
        case .busy(.stopping): String(localized: "Processing is stopping. Try again in a moment.")
        case .busy(.integrations): String(localized: "Finish reviewing integration deliveries first.")
        case .busy(.queueEdit): String(localized: "The queue is updating. Try again in a moment.")
        }
    }

    var resolutions: [RecordingResolution] {
        switch self {
        case .queued(let id), .pendingReprocess(let id): [.showInQueue(id)]
        case .unfinishedRun(let id): [.showInQueue(id), .discardRunAndRetranscribe(id)]
        default: []
        }
    }
}

/// The one rule table for actions on a recording. Every surface (menu panel, library,
/// viewer, menu bar) disables from it, and the manager re-checks it against disk.
enum RecordingEligibility {
    static func block(for action: RecordingAction, ownership: RecordingOwnership,
                      activity: AppActivity) -> RecordingBlock? {
        // This recording's own work first: it is the most specific answer.
        if ownership.isCaptureOrReview { return .underReview }
        if ownership.isHeldForSpeakerReview { return .speakerReview }
        if ownership.isActiveJob { return .processingNow }
        if let id = ownership.pendingAttemptID { return .pendingReprocess(id) }
        if action == .edit { return nil }
        if action != .delete {
            if let id = ownership.queueMarkerID { return .queued(id) }
            if let id = ownership.unfinishedJobID { return .unfinishedRun(id) }
        }
        // App-wide state.
        if !activity.recoveryReady { return .startingUp }
        if activity.unreadableRecords { return .unreadableRecords }
        if let operation = activity.operation { return .busy(operation) }
        if action == .delete {
            if let title = activity.activeJobTitle { return .otherJobRunning(title) }
            if activity.captureOrReviewOpen { return .recordingInProgress }
        }
        return nil
    }
}

/// Thrown when a click arrives after the work owning a recording changed.
struct RecordingBlockedError: LocalizedError, Equatable {
    let block: RecordingBlock
    var errorDescription: String? { block.message }
}

extension RecordingOwnership {
    /// One spelling per recording, however its URL was reached (symlinks, `..`).
    static func key(for url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    /// Saved work per recording, from the queue markers, jobs and delivery batches
    /// `refreshWorkQueue` loads. With unreadable deliveries (`completedDeliveryIDs` nil)
    /// every job that is not completed still owns its recording.
    static func index(queued: [(audioURL: URL, id: UUID)], jobs: [PersistedProcessingJob],
                      completedDeliveryIDs: Set<UUID>?) -> [String: RecordingOwnership] {
        var index: [String: RecordingOwnership] = [:]
        for entry in queued { index[key(for: entry.audioURL), default: .init()].queueMarkerID = entry.id }
        for job in jobs where job.dismissedFromQueue != true && job.status != .completed {
            let finished = completedDeliveryIDs.map { job.isFinished(completedDeliveryIDs: $0) } ?? false
            guard let path = job.source.finalizedAudioPath, !finished else { continue }
            let key = key(for: URL(fileURLWithPath: path))
            if index[key]?.unfinishedJobID == nil { index[key, default: .init()].unfinishedJobID = job.id }
        }
        return index
    }
}
