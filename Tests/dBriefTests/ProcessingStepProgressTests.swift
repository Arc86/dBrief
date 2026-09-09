import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Processing progress ownership") @MainActor
struct ProcessingStepProgressTests {
    private func fixture() -> (AppState, ProcessingJob, ProcessingStepProgress) {
        let state = AppState()
        let job = ProcessingJob(recording: Recording(fileURL: URL(fileURLWithPath: "/synthetic/audio.wav"), duration: 3))
        state.processingJob = job
        state.processingSteps = [.init(name: "Transcribing", status: .inProgress)]
        return (state, job, ProcessingStepProgress(appState: state, job: job, stepIndex: 0))
    }

    @Test func ownedProgressUpdatesJobWithoutTouchingConcurrentCapture() {
        let (state, job, progress) = fixture()
        let capture = Recording(fileURL: URL(fileURLWithPath: "/synthetic/capture.wav"), duration: 1)
        state.currentRecording = capture
        state.recordingState = .recording
        #expect(progress.update { step, owner in
            step.name = "Identifying speakers"
            step.progress = 0.75
            owner.transcriptionStartedAt = .distantPast
        })
        #expect(state.processingSteps[0].name == "Identifying speakers")
        #expect(job.transcriptionStartedAt == .distantPast)
        #expect(state.currentRecording === capture && state.recordingState == .recording)
    }

    @Test(arguments: ["replacementJob", "replacementStep", "completed", "failed", "missing", "ended"])
    func delayedProgressCannotWriteAfterItsOwnerChanges(boundary: String) async {
        let (state, job, progress) = fixture()
        // Queue a callback, then change ownership before it can enter MainActor.
        let callback = Task { @MainActor in
            progress.update { step, owner in
                step.name = "Stale callback"
                owner.transcriptionStartedAt = .distantPast
            }
        }
        switch boundary {
        case "replacementJob": state.processingJob = ProcessingJob(recording: job.recording)
        case "replacementStep": state.processingSteps[0] = .init(name: "New segment", status: .inProgress)
        case "completed": state.processingSteps[0].status = .completed
        case "failed": state.processingSteps[0].status = .failed("Stopped")
        case "missing": state.processingSteps = []
        default: progress.invalidate()
        }
        #expect(await callback.value == false)
        #expect(job.transcriptionStartedAt == nil)
        #expect(state.processingSteps.first?.name != "Stale callback")
    }

    @Test func callbackFromEarlierSegmentCannotUpdateNextSegmentInSameStep() async {
        let (state, job, first) = fixture()
        first.invalidate()
        let second = ProcessingStepProgress(appState: state, job: job, stepIndex: 0)
        #expect(second.update { step, _ in step.name = "Segment 2" })
        #expect(!first.update { step, _ in step.name = "Segment 1" })
        #expect(state.processingSteps[0].name == "Segment 2")
    }

    @Test func cancelledCallbackCannotPublishEvenWhileJobStillOwnsUI() async {
        let (state, _, progress) = fixture()
        let callback = Task { @MainActor in progress.update { step, _ in step.name = "Cancelled" } }
        callback.cancel()
        #expect(await callback.value == false)
        #expect(state.processingSteps[0].name == "Transcribing")
    }

    @Test func cancelledJobRejectsUncancelledCallback() async {
        let (state, job, progress) = fixture()
        let task = Task { @MainActor in }
        task.cancel()
        job.task = task
        #expect(!progress.update { step, _ in step.name = "Cancelled job" })
        #expect(state.processingSteps[0].name == "Transcribing")
        await task.value
    }

    @Test func localStreamKeepsLiveSegmentsOnOwningJobAndRejectsLateDelivery() async {
        let (state, job, progress) = fixture()
        let segment = LiveTranscriptSegment(start: 0, end: 2, text: "Synthetic speech")
        state.liveTranscriptSegments = [.init(start: 0, end: 1, text: "Concurrent capture")]
        let context = PrivacyTrace.Context(receiptURL: URL(fileURLWithPath: "/synthetic/privacy.json"), recordingID: job.recording.id)
        await PrivacyTrace.$context.withValue(context) {
            let callback = Task { @MainActor in
                #expect(PrivacyTrace.context?.runID == context.runID)
                #expect(progress.applyPluginState(.downloading(progress: 0.5, stage: .whisperModel)))
                #expect(state.processingSteps[0].progress == 0.5)
                #expect(progress.applyPluginState(.downloading(progress: 1, stage: .whisperModelLoading)))
                #expect(state.processingSteps[0].progress == nil)
                #expect(progress.applyPluginState(.newSegments([segment])))
            }
            await callback.value
        }
        #expect(job.progressiveSegments.map(\.text) == ["Synthetic speech"])
        #expect(job.transcriptionStartedAt != nil)
        #expect(state.liveTranscriptSegments.map(\.text) == ["Concurrent capture"])
        progress.invalidate()
        #expect(!progress.applyPluginState(.newSegments([segment])))
        #expect(job.progressiveSegments.count == 1)
    }

    @Test func parakeetStreamPreservesLoadingAndSpeakerStates() {
        let (state, job, progress) = fixture()
        #expect(progress.applyParakeetState(.downloading(progress: 0.6, stage: .parakeetModel)))
        #expect(state.processingSteps[0].progress == 0.6)
        #expect(progress.applyParakeetState(.downloading(progress: 1, stage: .parakeetModelLoading)))
        #expect(state.processingSteps[0].progress == nil)
        #expect(progress.applyParakeetState(.transcribing))
        #expect(job.transcriptionStartedAt != nil)
        #expect(progress.applyParakeetState(.diarizing))
        #expect(state.processingSteps[0].name == "Identifying speakers")
        state.processingJob = nil
        #expect(!progress.applyParakeetState(.transcribing))
        #expect(state.processingSteps[0].name == "Identifying speakers")
    }
}
