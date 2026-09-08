import Foundation
import Testing
@testable import dBrief

@Suite("Post-recording action ownership")
@MainActor
struct PostRecordingActionStateTests {
    @Test func startsWithNoWorkOrError() {
        let state = PostRecordingActionState()
        #expect(!state.isBusy)
        #expect(state.action == nil)
        #expect(state.progress == nil)
        #expect(state.error == nil)
    }

    @Test(arguments: [PostRecordingActionState.Action.process, .queue, .skip, .delete])
    func rejectsEveryActionWhileSaving(action: PostRecordingActionState.Action) throws {
        let state = PostRecordingActionState()
        let recordingID = UUID()
        let token = try #require(state.begin(recordingID: recordingID, action: .queue))
        #expect(state.begin(recordingID: recordingID, action: action) == nil)
        #expect(state.begin(recordingID: UUID(), action: action) == nil)
        #expect(state.token == token)
        #expect(state.recordingID == recordingID)
        #expect(state.action == .queue)
    }

    @Test func reservationSurvivesActorSuspension() async throws {
        let state = PostRecordingActionState()
        let recordingID = UUID()
        let token = try #require(state.begin(recordingID: recordingID, action: .queue))
        // Mimics another click reaching the manager while finalization is suspended.
        let duplicate = Task { @MainActor in
            state.begin(recordingID: recordingID, action: .process)
        }
        #expect(await duplicate.value == nil)
        #expect(state.isBusy)
        state.finish(token: token)
        #expect(!state.isBusy)
    }

    @Test func failureReleasesOwnershipAndRetryClearsError() throws {
        let state = PostRecordingActionState()
        let recordingID = UUID()
        let token = try #require(state.begin(recordingID: recordingID, action: .skip))
        state.updateProgress(0.4, token: token)
        state.finish(token: token, error: "Disk full")
        // A deferred success cleanup must not overwrite the failure.
        state.finish(token: token)
        #expect(!state.isBusy)
        #expect(state.progress == nil)
        #expect(state.error == "Disk full")
        #expect(state.recordingID == recordingID)
        #expect(state.begin(recordingID: recordingID, action: .queue) != nil)
        #expect(state.error == nil)
    }

    @Test func lateCallbacksCannotChangeNextAction() throws {
        let state = PostRecordingActionState()
        let recordingID = UUID()
        let old = try #require(state.begin(recordingID: recordingID, action: .queue))
        state.finish(token: old, error: "Temporary failure")
        let current = try #require(state.begin(recordingID: recordingID, action: .queue))
        state.updateProgress(0.3, token: current)
        state.updateProgress(1, token: old)
        state.finish(token: old, error: "Stale failure")
        #expect(state.token == current)
        #expect(state.progress == 0.3)
        #expect(state.error == nil)
    }

    @Test func progressIsFiniteClampedAndMonotonic() throws {
        let state = PostRecordingActionState()
        let token = try #require(state.begin(recordingID: UUID(), action: .queue))
        state.updateProgress(.nan, token: token)
        state.updateProgress(.infinity, token: token)
        #expect(state.progress == nil)
        state.updateProgress(-1, token: token)
        #expect(state.progress == 0)
        state.updateProgress(0.7, token: token)
        state.updateProgress(0.2, token: token)
        #expect(state.progress == 0.7)
        state.updateProgress(2, token: token)
        #expect(state.progress == 1)
        #expect(state.isBusy) // Metadata/queue persistence still owns the action.
    }

    @Test func successClearsProgressAndAllowsAnotherRecording() throws {
        let state = PostRecordingActionState()
        let token = try #require(state.begin(recordingID: UUID(), action: .process))
        state.updateProgress(1, token: token)
        state.finish(token: token)
        #expect(state.action == nil)
        #expect(state.progress == nil)
        #expect(state.error == nil)
        let next = UUID()
        #expect(state.begin(recordingID: next, action: .skip) != nil)
        #expect(state.recordingID == next)
    }
}
