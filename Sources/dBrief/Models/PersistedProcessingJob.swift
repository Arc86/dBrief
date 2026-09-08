import Foundation

/// Durable intent, stage checkpoints, and a frozen pending Markdown export.
/// Transcript and analysis sidecars remain the canonical stage outputs.
struct PersistedProcessingJob: Codable, Equatable, Sendable, Identifiable {
    static let currentVersion = 1

    enum Status: String, Codable, Equatable, Sendable {
        case queued
        case running
        case waitingForSpeakerReview
        case failed
        case cancelled
        /// Transcription is durable, but a later Phase 5 stage was interrupted.
        /// Kept as a migration state for jobs created by Phase 5A builds.
        case transcriptionComplete
        /// Analysis is durable; Phase 5B does not automatically replay Markdown
        /// generation or integration delivery.
        case analysisComplete
        /// Markdown is durable; integration delivery still requires explicit action.
        case markdownComplete
        case completed
    }

    enum FailureStage: String, Codable, Equatable, Sendable {
        case persistence
        case finalization
        case transcription
        case diarization
        case speakerReview
        case analysis
        case markdown
        case integrations
        case missingInput
    }

    enum LaunchRecoveryAction: Equatable, Sendable {
        case resumeToMarkdownBoundary
        case parkAtMarkdownBoundary
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
    /// Frozen confirm-first decision for deterministic recovery. Nil on Phase 5A
    /// manifests, which recompute it once and persist the result.
    var speakerReviewRequired: Bool?
    /// Nil on older jobs. New jobs freeze whether analysis produced a sidecar,
    /// independent of the AI-enabled setting at the time recovery runs.
    var analysisOutputSaved: Bool?
    var markdownExport: MarkdownExportPlan?
    /// Explicit removal from queue/recovery is not a deletion of the recording.
    var dismissedFromQueue: Bool? = nil

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
        failureStage: FailureStage? = nil,
        speakerReviewRequired: Bool? = nil,
        analysisOutputSaved: Bool? = nil,
        markdownExport: MarkdownExportPlan? = nil
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
        self.speakerReviewRequired = speakerReviewRequired
        self.analysisOutputSaved = analysisOutputSaved
        self.markdownExport = markdownExport
    }

    mutating func markRunning(at date: Date) {
        dismissedFromQueue = false
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

    mutating func markWaitingForSpeakerReview(at date: Date) {
        status = .waitingForSpeakerReview
        failureStage = nil
        updatedAt = date
    }

    mutating func markAnalysisBoundaryReached(at date: Date) {
        status = .analysisComplete
        failureStage = nil
        updatedAt = date
    }

    mutating func markFullyCompleted(at date: Date) {
        status = .completed
        failureStage = nil
        updatedAt = date
    }

    mutating func markMarkdownBoundaryReached(at date: Date) {
        status = .markdownComplete
        failureStage = nil
        updatedAt = date
    }

    var hasDurableTranscription: Bool {
        guard let stage = checkpoint.lastCompletedStage else { return false }
        return stage != .audioFinalized
    }

    /// Recovery advances through local Markdown publication but never automatically
    /// repeats integration delivery. Earlier beta boundary states migrate forward.
    var launchRecoveryAction: LaunchRecoveryAction {
        if dismissedFromQueue == true { return .none }
        switch status {
        case .completed, .failed, .cancelled, .markdownComplete:
            return .none
        case .waitingForSpeakerReview:
            return .resumeToMarkdownBoundary
        case .queued:
            return .none
        case .running, .transcriptionComplete, .analysisComplete:
            if checkpoint.hasCompleted(.markdownGenerated) {
                return .parkAtMarkdownBoundary
            }
            return .resumeToMarkdownBoundary
        }
    }
}
