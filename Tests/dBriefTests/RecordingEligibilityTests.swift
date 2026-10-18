import Foundation
import Testing
@testable import dBrief

@Suite struct RecordingEligibilityTests {
    private let idle = AppActivity()
    private let run = UUID(), attempt = UUID(), marker = UUID()

    private func block(_ action: RecordingAction, _ ownership: RecordingOwnership = .init(),
                       _ activity: AppActivity = .init()) -> RecordingBlock? {
        RecordingEligibility.block(for: action, ownership: ownership, activity: activity)
    }

    @Test func anIdleRecordingAllowsEverything() {
        for action in RecordingAction.allCases { #expect(block(action) == nil) }
    }

    /// The reported case: a recording with an unfinished run in Queue & Recovery.
    @Test func unfinishedRunBlocksReprocessWithAOneStepFix() throws {
        let owned = RecordingOwnership(unfinishedJobID: run)
        let reprocess = try #require(block(.reprocess, owned))
        #expect(reprocess == .unfinishedRun(run))
        #expect(reprocess.resolutions == [.showInQueue(run), .discardRunAndRetranscribe(run)])
        #expect(reprocess.message.contains("Queue & Recovery"))
        #expect(block(.linkCalendar, owned) == .unfinishedRun(run))
        // Editing and deleting were never blocked by a leftover run.
        #expect(block(.edit, owned) == nil)
        #expect(block(.delete, owned) == nil)
    }

    @Test func queuedAndPendingReprocessPointToTheQueue() {
        let queued = RecordingOwnership(queueMarkerID: marker)
        #expect(block(.reprocess, queued) == .queued(marker))
        #expect(block(.reprocess, queued)?.resolutions == [.showInQueue(marker)])
        #expect(block(.delete, queued) == nil)
        let pending = RecordingOwnership(pendingAttemptID: attempt)
        for action in RecordingAction.allCases {
            #expect(block(action, pending) == .pendingReprocess(attempt))
        }
        #expect(block(.edit, pending)?.resolutions == [.showInQueue(attempt)])
    }

    @Test func thisRecordingsOwnWorkWinsOverEverythingElse() {
        let reviewing = RecordingOwnership(isActiveJob: true, isHeldForSpeakerReview: true)
        #expect(block(.reprocess, reviewing) == .speakerReview)
        let processing = RecordingOwnership(unfinishedJobID: run, isActiveJob: true)
        for action in RecordingAction.allCases { #expect(block(action, processing) == .processingNow) }
        let underReview = RecordingOwnership(isCaptureOrReview: true)
        for action in RecordingAction.allCases { #expect(block(action, underReview) == .underReview) }
    }

    /// Another recording's work no longer blocks reprocessing (it queues) or calendar linking.
    @Test func unrelatedWorkOnlyBlocksDelete() {
        let busy = AppActivity(activeJobTitle: "Weekly sync", captureOrReviewOpen: true)
        #expect(block(.reprocess, .init(), busy) == nil)
        #expect(block(.linkCalendar, .init(), busy) == nil)
        #expect(block(.edit, .init(), busy) == nil)
        #expect(block(.delete, .init(), busy) == .otherJobRunning("Weekly sync"))
        #expect(block(.delete, .init(), busy)?.message.contains("“Weekly sync”") == true)
        #expect(block(.delete, .init(), AppActivity(captureOrReviewOpen: true)) == .recordingInProgress)
    }

    @Test func globalStatesExplainThemselvesButNeverBlockEditing() {
        let starting = AppActivity(recoveryReady: false)
        #expect(block(.reprocess, .init(), starting) == .startingUp)
        #expect(block(.edit, .init(), starting) == nil)
        let unreadable = AppActivity(unreadableRecords: true)
        #expect(block(.reprocess, .init(), unreadable) == .unreadableRecords)
        #expect(block(.delete, .init(), unreadable) == .unreadableRecords)
        #expect(block(.edit, .init(), unreadable) == nil)
        let saving = AppActivity(operation: .saving)
        #expect(block(.linkCalendar, .init(), saving) == .busy(.saving))
        #expect(block(.edit, .init(), saving) == nil)
    }

    @Test func everyBlockHasAMessage() {
        let blocks: [RecordingBlock] = [.startingUp, .processingNow, .underReview, .speakerReview, .queued(marker),
            .unfinishedRun(run), .pendingReprocess(attempt), .otherJobRunning("X"), .recordingInProgress,
            .unreadableRecords] + AppActivity.Operation.allCases.map { .busy($0) }
        for block in blocks { #expect(!block.message.isEmpty) }
    }
}
