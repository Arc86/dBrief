import Foundation

extension ProcessingPipeline {
    enum ExportWorkflowMode: Sendable { case processing, retry }
    struct ExportWorkflowRequest: Sendable {
        let mode: ExportWorkflowMode
        let analysisAlreadyCompleted: Bool
        var runAnalysis: Bool
        let analysisRequested: Bool
        let writeMarkdown: Bool
        let stopBeforeIntegrations: Bool
    }
    enum ExportWorkflowResult: Sendable { case completed, held, failed }
    enum ExportWorkflowPhase: Sendable {
        case loadingAnalysis, analyzing, savingAnalysis, writingMarkdown, checkpointingMarkdown
    }
    enum ExportFailureDisposition: Sendable { case stop, stopAndQueue, continueWorkflow }
    struct ExportWorkflowFailure: Sendable {
        let phase: ExportWorkflowPhase
        let disposition: ExportFailureDisposition
        let underlying: any Error
    }
    struct ExportWorkflowSteps: Sendable {
        var restoreAnalysis: @Sendable () async throws -> Void
        var analyze: @Sendable () async throws -> Void
        var saveAnalysis: @Sendable () async throws -> Void
        var checkpointAnalysis: @Sendable (_ outputSaved: Bool) async throws -> Void
        var title: @Sendable () async throws -> Void
        var performance: @Sendable () async throws -> Void
        var markdown: @Sendable (ExportWorkflowMode) async throws -> URL
        var persistTitle: @Sendable () async throws -> Void
        var updateExportLink: @Sendable (URL) async throws -> Void
        var saveRetryInsights: @Sendable (URL) async throws -> Void
        var prepareDeliveries: @Sendable (URL?) async throws -> Void
        var checkpointMarkdown: @Sendable () async throws -> Void
        var markdownCommitted: @Sendable () async throws -> Void
        var dispatch: @Sendable (URL?, _ held: Bool) async throws -> Bool
        var reportFailure: @Sendable (ExportWorkflowFailure) async throws -> Void
        var validateOwnership: @Sendable () async throws -> Void = {}
    }

    /// Shared normal/recovery/review-resume/retry routing. Each adapter performs
    /// one operation; this actor owns stage order and the distinct failure policies.
    func analysisExportWorkflow(_ request: ExportWorkflowRequest, steps: ExportWorkflowSteps) async throws -> ExportWorkflowResult {
        try await validateExportWorkflow(steps)
        let retry = request.mode == .retry
        let restored = !retry && request.analysisAlreadyCompleted
        if restored {
            do {
                try await steps.restoreAnalysis()
                try await validateExportWorkflow(steps)
            } catch {
                try await reportExportWorkflowFailure(error, phase: .loadingAnalysis, disposition: .stopAndQueue, steps: steps)
                return .failed
            }
        }
        if !restored, request.runAnalysis {
            do {
                try await steps.analyze()
                try await validateExportWorkflow(steps)
            } catch {
                try await reportExportWorkflowFailure(error, phase: .analyzing, disposition: .stopAndQueue, steps: steps)
                return .failed
            }
        }
        if !retry, !restored {
            do {
                if request.analysisRequested {
                    try await steps.saveAnalysis()
                    try await validateExportWorkflow(steps)
                }
                try await steps.checkpointAnalysis(request.analysisRequested)
                try await validateExportWorkflow(steps)
            } catch {
                try await reportExportWorkflowFailure(error, phase: .savingAnalysis, disposition: .stop, steps: steps)
                return .failed
            }
        }

        var markdownURL: URL?
        if retry || request.writeMarkdown {
            // Retry historically records AI timing before the optional title;
            // normal processing includes title timing with transcription metrics.
            if retry {
                try await steps.performance()
                try await validateExportWorkflow(steps)
            }
            do { try await steps.title() }
            catch { try await validateExportWorkflow(steps) } // non-critical title fallback
            try await validateExportWorkflow(steps)
            if !retry {
                try await steps.performance()
                try await validateExportWorkflow(steps)
            }
            do {
                let url = try await steps.markdown(request.mode)
                try await validateExportWorkflow(steps)
                markdownURL = url
                if retry {
                    try await steps.markdownCommitted()
                    try await validateExportWorkflow(steps)
                }
                try await steps.persistTitle()
                try await validateExportWorkflow(steps)
                if retry {
                    // Preserve explicit retry's best-effort insights save without
                    // swallowing owning-task cancellation or ownership loss.
                    do { try await steps.saveRetryInsights(url) }
                    catch { try await validateExportWorkflow(steps) }
                    try await validateExportWorkflow(steps)
                } else {
                    try await steps.updateExportLink(url)
                    try await validateExportWorkflow(steps)
                    try await steps.prepareDeliveries(url)
                    try await validateExportWorkflow(steps)
                    try await steps.checkpointMarkdown()
                    try await validateExportWorkflow(steps)
                    try await steps.markdownCommitted()
                    try await validateExportWorkflow(steps)
                }
            } catch {
                try await reportExportWorkflowFailure(error, phase: .writingMarkdown,
                    disposition: retry ? .continueWorkflow : .stopAndQueue, steps: steps)
                if !retry { return .failed }
            }
        } else {
            do {
                try await steps.prepareDeliveries(nil)
                try await validateExportWorkflow(steps)
                try await steps.checkpointMarkdown()
                try await validateExportWorkflow(steps)
            } catch {
                try await reportExportWorkflowFailure(error, phase: .checkpointingMarkdown, disposition: .stopAndQueue, steps: steps)
                return .failed
            }
        }
        try await validateExportWorkflow(steps)
        let held = !retry && request.stopBeforeIntegrations
        let delivered = try await steps.dispatch(markdownURL, held)
        try await validateExportWorkflow(steps)
        guard delivered else { return .failed }
        return held ? .held : .completed
    }

    private func validateExportWorkflow(_ steps: ExportWorkflowSteps) async throws {
        try Task.checkCancellation()
        try await steps.validateOwnership()
        try Task.checkCancellation()
    }

    private func reportExportWorkflowFailure(_ error: any Error, phase: ExportWorkflowPhase,
                                             disposition: ExportFailureDisposition, steps: ExportWorkflowSteps) async throws {
        // A backend may independently throw CancellationError; only the owning
        // task/ownership check suppresses failure handling and downstream effects.
        try await validateExportWorkflow(steps)
        try await steps.reportFailure(.init(phase: phase, disposition: disposition, underlying: error))
        try await validateExportWorkflow(steps)
    }
}
