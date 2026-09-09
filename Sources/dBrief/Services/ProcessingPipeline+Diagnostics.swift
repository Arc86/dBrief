import Foundation

extension ProcessingPipeline {
    /// Fixed event names and aggregate facts keep recording content out of the
    /// diagnostic journal. The observable manager snapshots these facts before
    /// dispatch, then revalidates job ownership before any subsequent UI work.
    enum ProcessingDiagnostic: Sendable {
        case started(transcribe: Bool, summary: Bool, actionItems: Bool, tags: Bool)
        case transcriptionFailed(DurabilityDiagnosticFailure)
        case completed(stepCount: Int, failedStepCount: Int)
    }

    /// This records an already-observed event for the captured recording, even
    /// if its caller is cancelled while waiting for the actor. It never publishes
    /// UI or checkpoints and keeps the journal's existing best-effort policy.
    func recordProcessingDiagnostic(_ input: ProcessingDiagnostic, recordingID: UUID,
                                    record: @Sendable (DurabilityEvent) -> Void = { DurabilityJournal.shared.record($0) }) {
        let event: DurabilityEvent
        switch input {
        case let .started(transcribe, summary, actionItems, tags):
            event = .init(timestamp: now(), sessionID: recordingID, name: "processing_started", outcome: .started,
                measurements: ["transcriptionRequested": transcribe ? 1 : 0, "summaryRequested": summary ? 1 : 0,
                               "actionItemsRequested": actionItems ? 1 : 0, "tagsRequested": tags ? 1 : 0])
        case .transcriptionFailed(let failure):
            event = .init(timestamp: now(), sessionID: recordingID, name: "transcription", outcome: .failed, failure: failure)
        case let .completed(stepCount, failedStepCount):
            event = .init(timestamp: now(), sessionID: recordingID, name: "processing_completed",
                outcome: failedStepCount == 0 ? .succeeded : .warning,
                measurements: ["stepCount": Int64(stepCount), "failedStepCount": Int64(failedStepCount)])
        }
        record(event)
    }
}
