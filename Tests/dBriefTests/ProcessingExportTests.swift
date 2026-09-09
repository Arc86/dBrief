import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Processing export")
struct ProcessingExportTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor private func request(_ root: URL, mode: ProcessingPipeline.MarkdownMode) -> ProcessingPipeline.MarkdownRequest {
        let recording = Recording(fileURL: root.appendingPathComponent("audio.wav"), duration: 65)
        recording.generatedTitle = "Planning"
        recording.summary = "Summary"
        recording.actionItems = ["Do it"]
        recording.transcription = .init(text: "Transcript", segments: [])
        return .init(snapshot: .init(recording: recording), outputFolder: root, includeTranscript: true, mode: mode)
    }

    @Test @MainActor func normalExportSavesItsPlanBeforePublishingAndIncludesSnapshotContent() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let input = request(root, mode: .restartable(jobID: UUID(), savedPlan: nil, alreadyCompleted: false))
        let output = try await ProcessingPipeline().publishMarkdown(input, store: MarkdownOutputStore(), savePlan: { plan in
            #expect(!FileManager.default.fileExists(atPath: plan.destination.path))
            #expect(plan.content.contains("Summary") && plan.content.contains("Transcript"))
            #expect(plan.content.contains("1:05") && plan.content.contains("- [ ] Do it"))
        })
        #expect(try String(contentsOf: output.url, encoding: .utf8) == output.plan.content)
    }

    @Test @MainActor func savedCompletedPlanPreservesEditedNoteAndSkipsPreparation() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = MarkdownExportPlan(destination: root.appendingPathComponent("original.md"), content: "Original", generatedTitle: "Old title")
        try "Edited note".write(to: saved.destination, atomically: true, encoding: .utf8)
        let output = try await ProcessingPipeline().publishMarkdown(
            request(root, mode: .restartable(jobID: UUID(), savedPlan: saved, alreadyCompleted: true)),
            store: MarkdownOutputStore(), savePlan: { _ in Issue.record("Frozen plan must not be replaced") })
        #expect(output.plan == saved)
        #expect(try String(contentsOf: output.url, encoding: .utf8) == "Edited note")
    }

    @Test @MainActor func planFailureAndCancellationStopBeforePublication() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let input = request(root, mode: .restartable(jobID: UUID(), savedPlan: nil, alreadyCompleted: false))
        await #expect(throws: CocoaError.self) {
            _ = try await ProcessingPipeline().publishMarkdown(input, store: MarkdownOutputStore(), savePlan: { _ in
                throw CocoaError(.fileWriteOutOfSpace)
            })
        }
        let task = Task {
            try await ProcessingPipeline().publishMarkdown(input, store: MarkdownOutputStore(), savePlan: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test @MainActor func explicitRetryRetainsRegenerationBehaviorWithoutDurablePlanCallback() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let input = request(root, mode: .regenerate)
        let old = MarkdownGenerator().prepare(snapshot: input.snapshot, outputFolder: root, includeTranscript: true)
        try "Old generated content".write(to: old.destination, atomically: true, encoding: .utf8)
        let output = try await ProcessingPipeline().publishMarkdown(input, store: MarkdownOutputStore(),
            savePlan: { _ in Issue.record("AI retry does not create a processing plan checkpoint") })
        #expect(output.url == old.destination)
        #expect(try String(contentsOf: output.url, encoding: .utf8) == old.content)
    }

    @Test @MainActor func titleTranscriptPreparationPreservesSpeakerFormattingAndCancellation() async throws {
        let transcript = TranscriptionResult(text: "Ignored flattened text", segments: [
            .init(start: 0, end: 1, text: "First", speaker: "Speaker 1"),
            .init(start: 1, end: 2, text: "second", speaker: "Speaker 1"),
            .init(start: 2, end: 3, text: "Third", speaker: "Speaker 2")
        ])
        let pipeline = ProcessingPipeline()
        let text = try await pipeline.prepareTitleTranscript(transcript, format: {
            #expect(!Thread.isMainThread)
            return $0.textForLLM
        })
        #expect(text == "Speaker 1: First second\nSpeaker 2: Third")
        #expect(try await pipeline.prepareTitleTranscript(.init(text: "", segments: [])) == "")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pipeline.prepareTitleTranscript(transcript)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func titleUsesSummaryOrBoundedTranscriptAndFailureRemainsOptional() async throws {
        let pipeline = ProcessingPipeline()
        let endpoint = Endpoint(name: "Fixture", baseURL: "https://synthetic.invalid", modelName: "fixture")
        let result = try await pipeline.generateTitle(.init(transcription: String(repeating: "x", count: 700), summary: "Summary",
            language: "en", endpoint: endpoint), using: { input in
                #expect(input.transcription == "Summary" && input.language == "en")
                return "Title"
            })
        #expect(result.title == "Title" && result.duration != nil)
        let failed = try await pipeline.generateTitle(.init(transcription: String(repeating: "x", count: 700), summary: nil,
            language: nil, endpoint: endpoint), using: { input in
                #expect(input.transcription.count == 500)
                throw CocoaError(.fileReadUnknown)
            })
        #expect(failed.title == nil && failed.duration == nil)
    }

    @Test func cancelledTitleNeverReturnsAnOutput() async throws {
        let input = ProcessingPipeline.TitleRequest(transcription: "Text", summary: nil, language: nil,
            endpoint: .init(name: "Fixture", baseURL: "https://synthetic.invalid", modelName: "fixture"))
        let task = Task {
            try await ProcessingPipeline().generateTitle(input, using: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return "Cancelled title"
            })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
    @Test @MainActor func lostOwnershipStopsPlanSaveAndTitleProvider() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = ProcessingPipeline()
        await #expect(throws: CancellationError.self) {
            _ = try await pipeline.publishMarkdown(request(root, mode: .restartable(jobID: UUID(), savedPlan: nil, alreadyCompleted: false)),
                store: MarkdownOutputStore(), savePlan: { _ in Issue.record("Lost owner cannot save a plan") },
                validateOwnership: { throw CancellationError() })
        }
        await #expect(throws: CancellationError.self) {
            _ = try await pipeline.generateTitle(.init(transcription: "Text", summary: nil, language: nil,
                endpoint: .init(name: "Fixture", baseURL: "https://synthetic.invalid", modelName: "fixture")),
                using: { _ in Issue.record("Lost owner cannot call title provider"); return "Title" },
                validateOwnership: { throw CancellationError() })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func restoresRequiredAnalysisAndAdoptsLegacyNoteWithoutReplacingEdits() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("analysis.json")
        let note = root.appendingPathComponent("legacy.md")
        let pipeline = ProcessingPipeline()
        let insightsStore = InsightsStore()
        let markdownStore = MarkdownOutputStore()
        await #expect(throws: InsightsStoreError.self) {
            _ = try await pipeline.restoreAnalysis(from: url, required: true, adoptLegacyMarkdown: true,
                insightsStore: insightsStore, markdownStore: markdownStore)
        }
        #expect(try await pipeline.restoreAnalysis(from: nil, required: false, adoptLegacyMarkdown: false,
            insightsStore: insightsStore, markdownStore: markdownStore).insights == nil)
        try "Edited legacy note".write(to: note, atomically: true, encoding: .utf8)
        let insights = RecordingInsights(summary: "Saved summary", actionItems: [], tags: [], sentiment: "Neutral",
                                        generatedTitle: "Old title", markdownPath: note.path)
        try await pipeline.saveAnalysis(insights, to: url, store: insightsStore)
        let restored = try await pipeline.restoreAnalysis(from: url, required: true, adoptLegacyMarkdown: true,
            insightsStore: insightsStore, markdownStore: markdownStore)
        #expect(restored.insights == insights)
        #expect(restored.adoptedPlan?.content == "Edited legacy note" && restored.adoptedPlan?.destination == note)
    }

    @Test @MainActor func exportAndTitleCallbacksRetainPrivacyScope() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let context = PrivacyTrace.Context(receiptURL: root.appendingPathComponent("receipt.json"), recordingID: UUID())
        let input = request(root, mode: .restartable(jobID: UUID(), savedPlan: nil, alreadyCompleted: false))
        let pipeline = ProcessingPipeline(now: {
            #expect(!Thread.isMainThread)
            #expect(PrivacyTrace.context?.runID == context.runID)
            return Date()
        })
        try await PrivacyTrace.$context.withValue(context) {
            _ = try await pipeline.generateTitle(.init(transcription: "Text", summary: nil, language: nil,
                endpoint: .init(name: "Fixture", baseURL: "https://synthetic.invalid", modelName: "fixture")), using: { _ in
                    #expect(PrivacyTrace.context?.runID == context.runID)
                    return "Title"
                })
            _ = try await pipeline.publishMarkdown(input, store: MarkdownOutputStore(), savePlan: { @MainActor _ in
                MainActor.preconditionIsolated()
                #expect(PrivacyTrace.context?.runID == context.runID)
            })
        }
        #expect(FileManager.default.fileExists(atPath: context.receiptURL.path))
    }

}
