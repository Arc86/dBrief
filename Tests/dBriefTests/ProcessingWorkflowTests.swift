import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Processing analysis/export workflow")
struct ProcessingWorkflowTests {
    private actor Audit {
        var calls: [String] = []
        var failures: [ProcessingPipeline.ExportWorkflowFailure] = []
        let failAt: String?
        let cancelAt: String?
        init(failAt: String? = nil, cancelAt: String? = nil) {
            self.failAt = failAt; self.cancelAt = cancelAt
        }
        func add(_ value: String) throws {
            calls.append(value)
            if value == cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
            if value == failAt { throw CocoaError(.fileWriteOutOfSpace) }
        }
        func report(_ failure: ProcessingPipeline.ExportWorkflowFailure) {
            failures.append(failure)
            calls.append("failure")
        }
    }
    private let url = URL(fileURLWithPath: "/synthetic/note.md")
    private func request(retry: Bool = false, recovered: Bool = false, requested: Bool = true,
                         markdown: Bool = true, hold: Bool = false) -> ProcessingPipeline.ExportWorkflowRequest {
        .init(mode: retry ? .retry : .processing, analysisAlreadyCompleted: recovered,
              runAnalysis: true, analysisRequested: requested, writeMarkdown: markdown, stopBeforeIntegrations: hold)
    }
    private func steps(_ audit: Audit, delivered: Bool = true) -> ProcessingPipeline.ExportWorkflowSteps {
        .init(restoreAnalysis: { try await audit.add("restore") },
              analyze: { try await audit.add("analyze") },
              saveAnalysis: { try await audit.add("saveAnalysis") },
              checkpointAnalysis: { try await audit.add($0 ? "checkpointAnalysisSaved" : "checkpointAnalysisEmpty") },
              title: { try await audit.add("title") },
              performance: { try await audit.add("performance") },
              markdown: { mode in try await audit.add(mode == .retry ? "regenerate" : "markdown"); return url },
              persistTitle: { try await audit.add("persistTitle") },
              updateExportLink: { _ in try await audit.add("link") },
              saveRetryInsights: { _ in try await audit.add("retryInsights") },
              prepareDeliveries: { try await audit.add($0 == nil ? "prepareEmpty" : "prepare") },
              checkpointMarkdown: { try await audit.add("checkpointMarkdown") },
              markdownCommitted: { try await audit.add("markdownCommitted") },
              dispatch: { output, hold in
                  try await audit.add(hold ? "hold" : output == nil ? "dispatchEmpty" : "dispatch")
                  return delivered
              }, reportFailure: { await audit.report($0) })
    }

    @Test func normalProcessingCommitsAnalysisAndExportBeforeDelivery() async throws {
        let audit = Audit()
        let result = try await ProcessingPipeline().analysisExportWorkflow(request(), steps: steps(audit))
        #expect(result == .completed)
        #expect(await audit.calls == ["analyze", "saveAnalysis", "checkpointAnalysisSaved", "title", "performance", "markdown",
                                     "persistTitle", "link", "prepare", "checkpointMarkdown", "markdownCommitted", "dispatch"])
    }

    @Test func recoveryRestoresInsteadOfAnalyzingAndHoldsBeforeSending() async throws {
        let audit = Audit()
        let result = try await ProcessingPipeline().analysisExportWorkflow(request(recovered: true, hold: true), steps: steps(audit))
        #expect(result == .held)
        #expect(await audit.calls == ["restore", "title", "performance", "markdown", "persistTitle", "link",
                                     "prepare", "checkpointMarkdown", "markdownCommitted", "hold"])
    }

    @Test func noRequestedOutputStillFreezesDeliveryIntentAndCheckpoints() async throws {
        let audit = Audit()
        var input = request(requested: false, markdown: false)
        input.runAnalysis = false
        #expect(try await ProcessingPipeline().analysisExportWorkflow(input, steps: steps(audit)) == .completed)
        #expect(await audit.calls == ["checkpointAnalysisEmpty", "prepareEmpty", "checkpointMarkdown", "dispatchEmpty"])
    }

    @Test func explicitRetryRegeneratesAndKeepsItsSeparatePersistenceOrder() async throws {
        let audit = Audit()
        #expect(try await ProcessingPipeline().analysisExportWorkflow(request(retry: true), steps: steps(audit)) == .completed)
        #expect(await audit.calls == ["analyze", "performance", "title", "regenerate", "markdownCommitted", "persistTitle", "retryInsights", "dispatch"])
    }

    @Test(arguments: ["restore", "saveAnalysis", "checkpointAnalysisSaved", "markdown", "link", "prepare", "checkpointMarkdown"])
    func requiredStageFailureStopsBeforeDelivery(boundary: String) async throws {
        let audit = Audit(failAt: boundary)
        let result = try await ProcessingPipeline().analysisExportWorkflow(request(recovered: boundary == "restore"), steps: steps(audit))
        #expect(result == .failed)
        let calls = await audit.calls
        #expect(calls.last == "failure" && !calls.contains("dispatch"))
        let failure = try #require(await audit.failures.first)
        #expect(failure.disposition == (["saveAnalysis", "checkpointAnalysisSaved"].contains(boundary) ? .stop : .stopAndQueue))
        #expect(failure.phase == (boundary == "restore" ? .loadingAnalysis : ["saveAnalysis", "checkpointAnalysisSaved"].contains(boundary) ? .savingAnalysis : .writingMarkdown))
    }

    @Test func explicitRetryKeepsDispatchAvailableAfterMarkdownFailure() async throws {
        let audit = Audit(failAt: "regenerate")
        #expect(try await ProcessingPipeline().analysisExportWorkflow(request(retry: true), steps: steps(audit)) == .completed)
        #expect(await audit.calls == ["analyze", "performance", "title", "regenerate", "failure", "dispatchEmpty"])
        #expect(await audit.failures.first?.disposition == .continueWorkflow)
    }

    @Test func retryInsightsRemainBestEffortButCancellationIsNotSwallowed() async throws {
        let audit = Audit(failAt: "retryInsights")
        #expect(try await ProcessingPipeline().analysisExportWorkflow(request(retry: true), steps: steps(audit)) == .completed)
        #expect(await audit.failures.isEmpty)
        #expect(await audit.calls.last == "dispatch")
    }

    @Test(arguments: [true, false])
    func titleFailureIsNonCritical(retry: Bool) async throws {
        let audit = Audit(failAt: "title")
        #expect(try await ProcessingPipeline().analysisExportWorkflow(request(retry: retry), steps: steps(audit)) == .completed)
        #expect(await audit.failures.isEmpty)
    }

    @Test func independentBackendCancellationIsOneAnalysisFailureWithoutExport() async throws {
        let audit = Audit()
        var actions = steps(audit)
        actions.analyze = { throw CancellationError() }
        #expect(try await ProcessingPipeline().analysisExportWorkflow(request(), steps: actions) == .failed)
        #expect(await audit.calls == ["failure"])
        let failure = try #require(await audit.failures.first)
        #expect(failure.phase == .analyzing && failure.disposition == .stopAndQueue)
        #expect(failure.underlying is CancellationError)
    }

    @Test(arguments: [false, true])
    func incompleteDeliveryNeverReportsCompletion(hold: Bool) async throws {
        let audit = Audit()
        #expect(try await ProcessingPipeline().analysisExportWorkflow(request(hold: hold), steps: steps(audit, delivered: false)) == .failed)
    }

    @Test(arguments: ["analyze", "saveAnalysis", "checkpointAnalysisSaved", "title", "performance", "markdown", "persistTitle",
                      "link", "prepare", "checkpointMarkdown", "markdownCommitted", "dispatch", "restore", "retryInsights", "hold"])
    func cancellationStopsAfterEveryAwait(boundary: String) async throws {
        let audit = Audit(cancelAt: boundary)
        let input = request(retry: boundary == "retryInsights", recovered: boundary == "restore", hold: boundary == "hold")
        let task = Task { try await ProcessingPipeline().analysisExportWorkflow(input, steps: steps(audit)) }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await audit.calls.last == boundary)
        #expect(await audit.failures.isEmpty)
    }

    @Test func lostOwnershipAfterPersistencePreventsDelivery() async throws {
        let audit = Audit()
        var actions = steps(audit)
        actions.validateOwnership = { if (await audit.calls).contains("checkpointMarkdown") { throw CancellationError() } }
        await #expect(throws: CancellationError.self) {
            _ = try await ProcessingPipeline().analysisExportWorkflow(request(), steps: actions)
        }
        #expect(await audit.calls.last == "checkpointMarkdown")
        #expect(await audit.failures.isEmpty)
    }

    @Test func emptyExportCheckpointFailureUsesPersistenceRecovery() async throws {
        let audit = Audit(failAt: "checkpointMarkdown")
        var input = request(requested: false, markdown: false)
        input.runAnalysis = false
        #expect(try await ProcessingPipeline().analysisExportWorkflow(input, steps: steps(audit)) == .failed)
        let failure = try #require(await audit.failures.first)
        #expect(failure.phase == .checkpointingMarkdown && failure.disposition == .stopAndQueue)
        #expect(await audit.calls.last == "failure")
    }

    @Test @MainActor func workflowReentersStagesWithDurableOutputsAndOriginatingPrivacyScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let insightsURL = root.appendingPathComponent("fixture.insights.json")
        let recording = Recording(fileURL: root.appendingPathComponent("fixture.wav"), duration: 10)
        recording.generatedTitle = "Frozen fixture"
        recording.transcription = .init(text: "Synthetic text", segments: [])
        let pipeline = ProcessingPipeline()
        let insightsStore = InsightsStore()
        let markdownStore = MarkdownOutputStore()
        let context = PrivacyTrace.Context(receiptURL: root.appendingPathComponent("privacy.json"), recordingID: recording.id)
        let audit = Audit()
        var actions = steps(audit)
        actions.analyze = { @MainActor in
            MainActor.preconditionIsolated()
            #expect(PrivacyTrace.context?.runID == context.runID)
            recording.summary = "Synthetic analysis"
        }
        actions.saveAnalysis = { @MainActor in
            let insights = RecordingInsights(summary: recording.summary ?? "", actionItems: [], tags: [], sentiment: "", markdownPath: nil)
            try await pipeline.saveAnalysis(insights, to: insightsURL, store: insightsStore)
        }
        actions.checkpointAnalysis = { saved in
            let result = try await pipeline.restoreAnalysis(from: insightsURL, required: saved,
                adoptLegacyMarkdown: false, insightsStore: insightsStore, markdownStore: markdownStore)
            #expect(result.insights?.summary == "Synthetic analysis")
            #expect(PrivacyTrace.context?.recordingID == context.recordingID)
        }
        actions.markdown = { @MainActor _ in
            MainActor.preconditionIsolated()
            let input = ProcessingPipeline.MarkdownRequest(snapshot: .init(recording: recording), outputFolder: root, includeTranscript: true,
                mode: .restartable(jobID: context.runID, savedPlan: nil, alreadyCompleted: false))
            let output = try await pipeline.publishMarkdown(input, store: markdownStore, savePlan: { _ in
                #expect(PrivacyTrace.context?.runID == context.runID)
            })
            return output.url
        }
        actions.updateExportLink = { url in
            try await pipeline.updateAnalysisExportLink(at: insightsURL, markdownURL: url, generatedTitle: "Frozen fixture", store: insightsStore)
        }
        actions.dispatch = { url, held in
            #expect(!held && PrivacyTrace.context?.runID == context.runID)
            let url = try #require(url)
            #expect(try String(contentsOf: url, encoding: .utf8).contains("Synthetic analysis"))
            let insights = try #require(try await insightsStore.load(from: insightsURL))
            #expect(insights.markdownPath == url.path && insights.generatedTitle == "Frozen fixture")
            return true
        }
        let input = actions
        let result = try await PrivacyTrace.$context.withValue(context) {
            try await pipeline.analysisExportWorkflow(request(), steps: input)
        }
        #expect(result == .completed)
    }
}
