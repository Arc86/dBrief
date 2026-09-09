import Foundation

struct RecoveryQueueEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let title: String
    let audioURL: URL?
    let date: Date
    let status: String
    let isDelivery: Bool

    /// The library caches only these routing/status facts, never frozen export
    /// content or credentials. Both surfaces use the same inclusion rules below.
    struct JobFacts: Codable, Sendable {
        let id: UUID
        let recordingID: UUID
        let createdAt: Date
        let updatedAt: Date
        let status: PersistedProcessingJob.Status
        let failureStage: PersistedProcessingJob.FailureStage?
        let dismissedFromQueue: Bool?
        let markdownCompleted: Bool
        let title: String
        let audioPath: String?
        let recoveryManifestPath: String?
        let associatedApp: String

        init(_ job: PersistedProcessingJob) {
            id = job.id; recordingID = job.recordingID
            createdAt = job.createdAt; updatedAt = job.updatedAt
            status = job.status; failureStage = job.failureStage
            dismissedFromQueue = job.dismissedFromQueue
            markdownCompleted = job.checkpoint.hasCompleted(.markdownGenerated)
            title = job.source.meetingTitle
            audioPath = job.source.finalizedAudioPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            recoveryManifestPath = job.source.recoveryManifestPath
            associatedApp = job.source.associatedApp ?? ""
        }
    }

    struct DeliveryFacts: Codable, Sendable {
        let id: UUID
        let createdAt: Date
        let isComplete: Bool
        let dismissedFromQueue: Bool?
        let title: String
        let audioURL: URL
        let hasFailure: Bool

        init(_ batch: IntegrationDeliveryBatch) {
            id = batch.id; createdAt = batch.createdAt
            isComplete = batch.isComplete; dismissedFromQueue = batch.dismissedFromQueue
            title = batch.bundle.title; audioURL = batch.bundle.audioFileURL.standardizedFileURL
            hasFailure = batch.deliveries.contains {
                !$0.isComplete && ($0.status != .pending || $0.attempts > 0)
            }
        }
    }

    static func entries(jobs: [PersistedProcessingJob], deliveries: [IntegrationDeliveryBatch], queuedIDs: Set<UUID>, activeID: UUID?) -> [Self] {
        entries(jobFacts: jobs.map(JobFacts.init), deliveryFacts: deliveries.map(DeliveryFacts.init),
                queuedIDs: queuedIDs, activeID: activeID)
    }

    static func entries(jobFacts jobs: [JobFacts], deliveryFacts deliveries: [DeliveryFacts], queuedIDs: Set<UUID>, activeID: UUID?) -> [Self] {
        let unfinished = deliveries.filter { !$0.isComplete && $0.dismissedFromQueue != true }
        let deliveryIDs = Set(unfinished.map(\.id))
        let completedDeliveryIDs = Set(deliveries.filter(\.isComplete).map(\.id))
        var entries = jobs.compactMap { job -> Self? in
            guard job.id != activeID, !queuedIDs.contains(job.id), !deliveryIDs.contains(job.id),
                  job.status != .completed, job.dismissedFromQueue != true else { return nil }
            if job.markdownCompleted, completedDeliveryIDs.contains(job.id) { return nil }
            let status: String
            switch job.status {
            case .failed:
                switch job.failureStage {
                case .missingInput: status = "Recording unavailable"
                case .persistence: status = "Couldn't save progress"
                case .finalization: status = "Audio finalization failed"
                case .transcription: status = "Transcription failed"
                case .diarization: status = "Speaker detection failed"
                case .speakerReview: status = "Speaker review needs attention"
                case .analysis: status = "Analysis failed"
                case .markdown: status = "Markdown export failed"
                case .integrations: status = "Integration review needed"
                case nil: status = "Processing failed"
                }
            case .cancelled: status = "Stopped"
            case .waitingForSpeakerReview: status = "Speaker review needed"
            case .markdownComplete: status = "Integration review needed"
            case .queued: status = "Deferred"
            default: status = "Interrupted"
            }
            return Self(id: job.id, title: job.title,
                        audioURL: job.audioPath.map { URL(fileURLWithPath: $0) },
                        date: job.createdAt, status: status,
                        isDelivery: job.markdownCompleted)
        }
        entries += unfinished.compactMap { batch in
            guard batch.id != activeID, !queuedIDs.contains(batch.id),
                  !jobs.contains(where: { $0.id == batch.id && $0.dismissedFromQueue == true }) else { return nil }
            return Self(id: batch.id, title: batch.title, audioURL: batch.audioURL,
                        date: batch.createdAt, status: "Integration review needed", isDelivery: true)
        }
        return entries.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
    }
}
