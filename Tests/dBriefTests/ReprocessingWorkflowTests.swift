import Foundation
import Testing
@testable import dBrief

@Suite("Reprocessing stage routing")
struct ReprocessingWorkflowTests {
    actor Calls {
        var values: [String] = []
        func add(_ value: String) { values.append(value) }
    }

    @Test func resumesSavedStagesBeforePublishing() async throws {
        let calls = Calls()
        let result = try await ReprocessingWorkflow.run(
            stages: [.transcription, .speakers, .analysis], completed: [.transcription],
            execute: { stage in await calls.add(stage.rawValue); return .completed },
            checkpoint: { stage in await calls.add("saved-\(stage.rawValue)") },
            publish: { await calls.add("publish") })
        #expect(result == .completed)
        #expect(await calls.values == ["speakers", "saved-speakers", "analysis", "saved-analysis", "publish"])
    }

    @Test func failedAnalysisDoesNotPublishOrCheckpoint() async {
        struct Failure: Error {}
        let calls = Calls()
        do {
            _ = try await ReprocessingWorkflow.run(stages: [.analysis], completed: [],
                execute: { _ in throw Failure() },
                checkpoint: { _ in await calls.add("checkpoint") },
                publish: { await calls.add("publish") })
            Issue.record("Expected analysis failure")
        } catch { #expect(error is Failure) }
        #expect(await calls.values.isEmpty)
    }

    @Test func speakerReviewHoldsBeforeAnalysisAndPublication() async throws {
        let calls = Calls()
        let result = try await ReprocessingWorkflow.run(stages: [.speakers, .analysis], completed: [],
            execute: { stage in await calls.add(stage.rawValue); return .held },
            checkpoint: { _ in await calls.add("checkpoint") },
            publish: { await calls.add("publish") })
        #expect(result == .held)
        #expect(await calls.values == ["speakers"])
    }

    @Test func owningTaskCancellationPreventsPublication() async {
        let calls = Calls()
        let task = Task {
            try await ReprocessingWorkflow.run(stages: [.transcription], completed: [],
                execute: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .completed
                },
                checkpoint: { _ in await calls.add("checkpoint") },
                publish: { await calls.add("publish") })
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(await calls.values.isEmpty)
    }
}
