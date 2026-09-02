import Foundation

/// Durable processing milestones in pipeline order. Phase 5 will persist this
/// contract after each successful stage; defining and testing it now prevents
/// resume semantics from being invented inside the pipeline refactor.
enum ProcessingCheckpointStage: String, CaseIterable, Codable, Hashable, Sendable {
    case audioFinalized
    case transcribed
    case diarized
    case speakerReviewCompleted
    case analyzed
    case markdownGenerated
    case integrationsDispatched

    fileprivate var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

/// Versioned, monotonic resume state for one processing job.
struct ProcessingCheckpoint: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let jobID: UUID
    private(set) var lastCompletedStage: ProcessingCheckpointStage?
    private(set) var updatedAt: Date

    init(
        version: Int = currentVersion,
        jobID: UUID,
        lastCompletedStage: ProcessingCheckpointStage? = nil,
        updatedAt: Date
    ) {
        self.version = version
        self.jobID = jobID
        self.lastCompletedStage = lastCompletedStage
        self.updatedAt = updatedAt
    }

    /// Advances the checkpoint, returning `true` only when durable state changed.
    /// Repeating a completed stage and attempting to move backwards are no-ops,
    /// which makes retries deterministic.
    @discardableResult
    mutating func markCompleted(_ stage: ProcessingCheckpointStage, at date: Date) -> Bool {
        if let lastCompletedStage, stage.order <= lastCompletedStage.order {
            return false
        }
        lastCompletedStage = stage
        updatedAt = date
        return true
    }

    var nextStage: ProcessingCheckpointStage? {
        guard let lastCompletedStage else { return ProcessingCheckpointStage.allCases.first }
        let nextIndex = lastCompletedStage.order + 1
        guard ProcessingCheckpointStage.allCases.indices.contains(nextIndex) else { return nil }
        return ProcessingCheckpointStage.allCases[nextIndex]
    }
}
