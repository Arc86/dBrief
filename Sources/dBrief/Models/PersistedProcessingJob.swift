import Foundation

/// Durable intent and resume state for the finalization → transcription slice of
/// the processing pipeline. Stage outputs remain in their canonical recording
/// sidecars; this record stores only the information needed to find and resume
/// them.
struct PersistedProcessingJob: Codable, Equatable, Sendable, Identifiable {
    static let currentVersion = 1

    enum Status: String, Codable, Equatable, Sendable {
        case queued
        case running
        case failed
        case cancelled
        /// Transcription is durable, but a later Phase 5 stage was interrupted.
        /// Phase 5A never automatically replays beyond this boundary because doing
        /// so could duplicate integrations.
        case transcriptionComplete
        case completed
    }

    enum FailureStage: String, Codable, Equatable, Sendable {
        case persistence
        case finalization
        case transcription
        case missingInput
    }

    enum LaunchRecoveryAction: Equatable, Sendable {
        case resumeToPhase5ABoundary
        case parkAtPhase5ABoundary
        case none
    }

    struct Request: Codable, Equatable, Sendable {
        let transcribe: Bool
        let summary: Bool
        let actionItems: Bool
        let tags: Bool
        let titleWasUserProvided: Bool
        /// Interrupted running jobs resume automatically. Explicitly deferred or
        /// cancelled work remains queued for user action.
        let autoResume: Bool
    }

    struct Source: Codable, Equatable, Sendable {
        let recordingDate: Date
        var duration: TimeInterval
        var fileSize: Int64
        var meetingTitle: String
        var associatedApp: String?
        var participants: [String]
        var calendarEvent: CalendarEvent?
        var echoSuppressionApplied: Bool

        var recoveryManifestPath: String?
        var stagedInputPath: String?
        var finalizedAudioPath: String?
        var segmentAudioPaths: [String]
        var metadataPath: String?
    }

    let version: Int
    let id: UUID
    let recordingID: UUID
    let createdAt: Date
    var updatedAt: Date
    var status: Status
    var request: Request
    var source: Source
    var checkpoint: ProcessingCheckpoint
    var failureStage: FailureStage?

    init(
        version: Int = currentVersion,
        id: UUID,
        recordingID: UUID,
        createdAt: Date,
        updatedAt: Date,
        status: Status,
        request: Request,
        source: Source,
        checkpoint: ProcessingCheckpoint? = nil,
        failureStage: FailureStage? = nil
    ) {
        self.version = version
        self.id = id
        self.recordingID = recordingID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.request = request
        self.source = source
        self.checkpoint = checkpoint ?? ProcessingCheckpoint(jobID: id, updatedAt: updatedAt)
        self.failureStage = failureStage
    }

    mutating func markRunning(at date: Date) {
        status = .running
        failureStage = nil
        updatedAt = date
    }

    @discardableResult
    mutating func markCompleted(_ stage: ProcessingCheckpointStage, at date: Date) -> Bool {
        guard checkpoint.markCompleted(stage, at: date) else { return false }
        updatedAt = date
        failureStage = nil
        return true
    }

    mutating func markFailed(_ stage: FailureStage, at date: Date) {
        status = .failed
        failureStage = stage
        updatedAt = date
    }

    mutating func markCancelled(at date: Date) {
        status = .cancelled
        updatedAt = date
    }

    mutating func markTranscriptionBoundaryReached(at date: Date) {
        status = .transcriptionComplete
        failureStage = nil
        updatedAt = date
    }

    mutating func markFullyCompleted(at date: Date) {
        status = .completed
        failureStage = nil
        updatedAt = date
    }

    var hasDurableTranscription: Bool {
        guard let stage = checkpoint.lastCompletedStage else { return false }
        return stage != .audioFinalized
    }

    /// Phase 5A recovery policy is deliberately narrower than the eventual full
    /// pipeline recovery: only a job that was running may resume, and no launch
    /// replay crosses into AI/export/integration work.
    var launchRecoveryAction: LaunchRecoveryAction {
        guard status == .running else { return .none }
        if hasDurableTranscription
            || (!request.transcribe
                && checkpoint.lastCompletedStage == .audioFinalized) {
            return .parkAtPhase5ABoundary
        }
        return .resumeToPhase5ABoundary
    }
}
