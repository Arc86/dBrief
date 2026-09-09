import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Processing preparation workflow")
struct ProcessingPreparationTests {
    private actor Audit {
        var calls: [String] = []
        func add(_ value: String) { calls.append(value) }
    }
    private var transcript: TranscriptionResult { .init(text: "Text", segments: []) }
    private func steps(_ audit: Audit, saved: Bool = false, held: Bool = false) -> ProcessingPipeline.PreparationSteps {
        .init(waitForCalendar: { await audit.add("calendar") }, finalize: { await audit.add("finalize") },
              finalizationCommitted: { await audit.add("finalized") }, meetingContext: { await audit.add("context") },
              prewarm: { await audit.add("prewarm") }, loadTranscript: { await audit.add("load"); return saved ? transcript : nil },
              transcribe: { await audit.add("transcribe"); return .init(transcription: transcript, model: "fixture", audioDuration: 10, spellCorrectionTime: 2) },
              publishTranscript: { _, loaded in await audit.add(loaded ? "publishSaved" : "publishNew") },
              saveTranscript: { _ in await audit.add("save") },
              checkpoint: { await audit.add("checkpoint:\($0.rawValue)") }, retireQueue: { await audit.add("retire") },
              transcriptCommitted: { _, fresh in await audit.add(fresh ? "count" : "reused") },
              speakers: { _, _ in await audit.add("speakers"); return held })
    }

    @Test func freshTranscriptCommitsBeforeQueueRetirementCounterAndSpeakerReview() async throws {
        let audit = Audit()
        let result = try await ProcessingPipeline().prepareWorkflow(transcribe: true, steps: steps(audit))
        #expect(await audit.calls == ["calendar", "finalize", "checkpoint:audioFinalized", "finalized", "context", "prewarm",
                                    "load", "transcribe", "publishNew", "save", "checkpoint:transcribed", "retire", "count", "speakers"])
        #expect(!result.heldForReview && result.perf.model == "fixture" && result.perf.audioDuration == 10)
        #expect(result.perf.spellCorrection == 2 && result.perf.time != nil && result.perf.finalization != nil)
    }

    @Test func savedTranscriptSkipsBackendSaveAndCounterAndCanHoldForReview() async throws {
        let audit = Audit()
        let result = try await ProcessingPipeline().prepareWorkflow(transcribe: true, steps: steps(audit, saved: true, held: true))
        let calls = await audit.calls
        #expect(result.heldForReview && result.perf.time == nil)
        #expect(!calls.contains("transcribe") && !calls.contains("save") && !calls.contains("count"))
        #expect(Array(calls.suffix(5)) == ["publishSaved", "checkpoint:transcribed", "retire", "reused", "speakers"])
    }

    @Test func noTranscriptionCheckpointsReviewWithoutTouchingTranscripts() async throws {
        let audit = Audit()
        let result = try await ProcessingPipeline().prepareWorkflow(transcribe: false, steps: steps(audit))
        #expect(!result.heldForReview)
        #expect(await audit.calls == ["calendar", "finalize", "checkpoint:audioFinalized", "finalized", "context", "prewarm", "checkpoint:speakerReviewCompleted"])
    }

    @Test func persistenceFailureKeepsQueueAndCounterUntouched() async throws {
        let audit = Audit()
        var actions = steps(audit)
        actions.saveTranscript = { _ in throw CocoaError(.fileWriteOutOfSpace) }
        do {
            _ = try await ProcessingPipeline().prepareWorkflow(transcribe: true, steps: actions)
            Issue.record("Expected persistence failure")
        } catch let failure as ProcessingPipeline.PreparationFailure {
            #expect(failure.stage == .persistence && failure.phase == .transcription)
        }
        let calls = await audit.calls
        #expect(!calls.contains("retire") && !calls.contains("count") && !calls.contains("speakers"))
    }

    @Test(arguments: ["calendar", "finalize", "publish", "checkpoint", "retire", "speakers"])
    func cancellationStopsAtEachBoundary(boundary: String) async throws {
        let audit = Audit()
        var actions = steps(audit)
        switch boundary {
        case "calendar": actions.waitForCalendar = { withUnsafeCurrentTask { $0?.cancel() } }
        case "finalize": actions.finalize = { withUnsafeCurrentTask { $0?.cancel() } }
        case "publish": actions.publishTranscript = { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
        case "checkpoint": actions.checkpoint = { if $0 == .transcribed { withUnsafeCurrentTask { $0?.cancel() } } }
        case "retire": actions.retireQueue = { withUnsafeCurrentTask { $0?.cancel() } }
        default: actions.speakers = { _, _ in withUnsafeCurrentTask { $0?.cancel() }; return true }
        }
        let input = actions
        let task = Task { try await ProcessingPipeline().prepareWorkflow(transcribe: true, steps: input) }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        if boundary != "speakers" { #expect(!(await audit.calls).contains("speakers")) }
    }

    @Test(arguments: ["finalize", "audioCheckpoint", "transcribe", "transcriptCheckpoint", "speakers"])
    func failuresRetainTheirStageAndStopLaterEffects(boundary: String) async throws {
        let audit = Audit()
        var actions = steps(audit)
        let expectedStage: PersistedProcessingJob.FailureStage
        let expectedPhase: ProcessingPipeline.PreparationPhase
        switch boundary {
        case "finalize":
            actions.finalize = { throw CocoaError(.fileReadUnknown) }
            expectedStage = .finalization; expectedPhase = .finalization
        case "audioCheckpoint":
            actions.checkpoint = { _ in throw CocoaError(.fileWriteOutOfSpace) }
            expectedStage = .persistence; expectedPhase = .finalization
        case "transcribe":
            // A backend can throw cancellation independently of the owning task.
            actions.transcribe = { throw CancellationError() }
            expectedStage = .transcription; expectedPhase = .transcription
        case "transcriptCheckpoint":
            actions.checkpoint = { if $0 == .transcribed { throw CocoaError(.fileWriteOutOfSpace) } }
            expectedStage = .persistence; expectedPhase = .transcription
        default:
            actions.speakers = { _, _ in
                throw ProcessingPipeline.PreparationFailure(stage: .speakerReview, phase: .speakers,
                                                            underlying: CocoaError(.fileWriteOutOfSpace))
            }
            expectedStage = .speakerReview; expectedPhase = .speakers
        }
        do {
            _ = try await ProcessingPipeline().prepareWorkflow(transcribe: true, steps: actions)
            Issue.record("Expected failure")
        } catch let failure as ProcessingPipeline.PreparationFailure {
            #expect(failure.stage == expectedStage && failure.phase == expectedPhase)
        }
        let calls = await audit.calls
        if boundary != "speakers" {
            #expect(!calls.contains("retire") && !calls.contains("count"))
        }
        if boundary == "transcriptCheckpoint" { #expect(calls.last == "save") }
    }

    @Test(arguments: [false, true])
    func lostOwnershipStopsBeforeAnyFurtherEffects(afterSave: Bool) async throws {
        let audit = Audit()
        var actions = steps(audit)
        actions.validateOwnership = {
            let calls = await audit.calls
            if !afterSave || calls.contains("save") { throw CancellationError() }
        }
        do {
            _ = try await ProcessingPipeline().prepareWorkflow(transcribe: true, steps: actions)
            Issue.record("Expected ownership rejection")
        } catch let failure as ProcessingPipeline.PreparationFailure {
            #expect(failure.underlying is CancellationError)
        }
        let calls = await audit.calls
        if afterSave { #expect(calls.last == "save") }
        else { #expect(calls.isEmpty) }
    }
}
