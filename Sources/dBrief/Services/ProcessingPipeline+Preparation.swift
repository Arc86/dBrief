import Foundation
import dBriefWire

extension ProcessingPipeline {
    enum PreparationPhase: Sendable, Equatable { case finalization, transcription, speakers }
    struct PreparationFailure: Error {
        let stage: PersistedProcessingJob.FailureStage
        let phase: PreparationPhase
        let underlying: any Error
    }
    struct WorkflowTranscription: Sendable {
        let transcription: TranscriptionResult
        let model: String?
        let audioDuration: TimeInterval
        let spellCorrectionTime: TimeInterval?
    }
    struct PreparationResult: Sendable {
        let perf: TranscriptionPerf
        let heldForReview: Bool
    }
    struct PreparationSteps: Sendable {
        var waitForCalendar: @Sendable () async throws -> Void
        var finalize: @Sendable () async throws -> Void
        var finalizationCommitted: @Sendable () async throws -> Void
        var meetingContext: @Sendable () async throws -> Void
        var prewarm: @Sendable () async throws -> Void
        var loadTranscript: @Sendable () async throws -> TranscriptionResult?
        var transcribe: @Sendable () async throws -> WorkflowTranscription
        var publishTranscript: @Sendable (TranscriptionResult, Bool) async throws -> Void
        var saveTranscript: @Sendable (TranscriptionResult) async throws -> Void
        var checkpoint: @Sendable (ProcessingCheckpointStage) async throws -> Void
        var retireQueue: @Sendable () async throws -> Void
        var transcriptCommitted: @Sendable (TranscriptionResult, Bool) async throws -> Void
        var speakers: @Sendable (TranscriptionResult, TranscriptionPerf) async throws -> Bool
        var validateOwnership: @Sendable () async throws -> Void = {}
    }

    /// Preparation policy lives here, independently of the observable recording.
    /// Adapters apply job-owned UI state and invoke the previously extracted stages.
    /// No queue retirement/counter/review is reachable before transcript durability.
    func prepareWorkflow(transcribe: Bool, steps: PreparationSteps) async throws -> PreparationResult {
        var phase: PreparationPhase = .finalization
        var failureStage: PersistedProcessingJob.FailureStage = .finalization
        var perf = TranscriptionPerf()
        do {
            try await validatePreparation(steps)
            try await steps.waitForCalendar()
            try await validatePreparation(steps)
            let finalizeStart = now()
            try await steps.finalize()
            try await validatePreparation(steps)
            failureStage = .persistence
            try await steps.checkpoint(.audioFinalized)
            try await validatePreparation(steps)
            perf.finalization = now().timeIntervalSince(finalizeStart)
            try await steps.finalizationCommitted()
            try await validatePreparation(steps)
            try await steps.meetingContext()
            try await validatePreparation(steps)
            try await steps.prewarm()
            try await validatePreparation(steps)

            if transcribe {
                phase = .transcription
                failureStage = .transcription
                let saved = try await steps.loadTranscript()
                try await validatePreparation(steps)
                let result: TranscriptionResult
                if let saved {
                    result = saved
                } else {
                    let start = now()
                    let fresh = try await steps.transcribe()
                    try await validatePreparation(steps)
                    result = fresh.transcription
                    perf.time = now().timeIntervalSince(start)
                    perf.inference = result.inferenceTime
                    perf.diarization = result.diarizationTime
                    perf.spellCorrection = fresh.spellCorrectionTime
                    perf.model = fresh.model
                    perf.audioDuration = fresh.audioDuration
                }
                try await steps.publishTranscript(result, saved != nil)
                try await validatePreparation(steps)
                failureStage = .persistence
                if saved == nil {
                    try await steps.saveTranscript(result)
                    try await validatePreparation(steps)
                }
                try await steps.checkpoint(.transcribed)
                try await validatePreparation(steps)
                try await steps.retireQueue()
                try await validatePreparation(steps)
                try await steps.transcriptCommitted(result, saved == nil)
                try await validatePreparation(steps)
                phase = .speakers
                failureStage = .diarization
                let held = try await steps.speakers(result, perf)
                try await validatePreparation(steps)
                return .init(perf: perf, heldForReview: held)
            }

            phase = .speakers
            failureStage = .persistence
            try await steps.checkpoint(.speakerReviewCompleted)
            try await validatePreparation(steps)
            return .init(perf: perf, heldForReview: false)
        } catch {
            try Task.checkCancellation()
            if let failure = error as? PreparationFailure { throw failure }
            throw PreparationFailure(stage: failureStage, phase: phase, underlying: error)
        }
    }

    private func validatePreparation(_ steps: PreparationSteps) async throws {
        try Task.checkCancellation()
        try await steps.validateOwnership()
        try Task.checkCancellation()
    }
}
