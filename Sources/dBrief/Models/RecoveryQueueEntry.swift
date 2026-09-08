import Foundation

struct RecoveryQueueEntry: Identifiable, Sendable {
    let id: UUID
    let title: String
    let audioURL: URL?
    let date: Date
    let status: String
    let isDelivery: Bool

    static func entries(jobs: [PersistedProcessingJob], deliveries: [IntegrationDeliveryBatch], queuedIDs: Set<UUID>, activeID: UUID?) -> [Self] {
        let unfinished = deliveries.filter { !$0.isComplete && $0.dismissedFromQueue != true }
        let deliveryIDs = Set(unfinished.map(\.id))
        let completedDeliveryIDs = Set(deliveries.filter(\.isComplete).map(\.id))
        var entries = jobs.compactMap { job -> Self? in
            guard job.id != activeID, !queuedIDs.contains(job.id), !deliveryIDs.contains(job.id),
                  job.status != .completed, job.dismissedFromQueue != true else { return nil }
            if job.checkpoint.hasCompleted(.markdownGenerated), completedDeliveryIDs.contains(job.id) { return nil }
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
            return Self(id: job.id, title: job.source.meetingTitle,
                        audioURL: job.source.finalizedAudioPath.map { URL(fileURLWithPath: $0) },
                        date: job.createdAt, status: status,
                        isDelivery: job.checkpoint.hasCompleted(.markdownGenerated))
        }
        entries += unfinished.compactMap { batch in
            guard batch.id != activeID, !queuedIDs.contains(batch.id),
                  !jobs.contains(where: { $0.id == batch.id && $0.dismissedFromQueue == true }) else { return nil }
            return Self(id: batch.id, title: batch.bundle.title, audioURL: batch.bundle.audioFileURL,
                        date: batch.createdAt, status: "Integration review needed", isDelivery: true)
        }
        return entries.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
    }
}
