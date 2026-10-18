import Foundation
import Testing
@testable import dBrief

/// The menu panel's Recent recordings used to judge status from sidecar files alone,
/// so a recording processing right now read "Recorded" and a failed run read "Analyzed".
@Suite struct RecordingStatusOwnershipTests {
    @Test func runningAndSavedWorkOverrideTheSidecarStatus() {
        #expect(RecordingStatus.resolve(ownership: .init(isActiveJob: true), saved: .analyzed) == .processing)
        #expect(RecordingStatus.resolve(ownership: .init(isCaptureOrReview: true), saved: .recorded) == .processing)
        #expect(RecordingStatus.resolve(ownership: .init(pendingAttemptID: UUID()), saved: .analyzed) == .reprocessPending)
        #expect(RecordingStatus.resolve(ownership: .init(queueMarkerID: UUID()), saved: .recorded) == .queued)
        #expect(RecordingStatus.resolve(ownership: .init(unfinishedJobID: UUID()), saved: .analyzed) == .needsAttention)
        #expect(RecordingStatus.resolve(ownership: .init(), saved: .transcribed) == .transcribed)
    }

    @Test func attentionStatesStandOut() {
        for status in [RecordingStatus.processing, .reprocessPending, .needsAttention] {
            #expect(status.systemImage != nil && status.tone != nil && !status.label.isEmpty)
        }
    }
}

/// The menu panel and the library used two vocabularies for the same recording
/// ("Recorded" vs "Unprocessed", "Analyzed" vs "Done", no failed state in the panel).
@Suite struct RecordingStatusVocabularyTests {
    @Test func bothListsUseTheSameWords() {
        #expect(RecordingStatus.recorded.label == LibraryRecordingStatus.unprocessed.title)
        #expect(LibraryRecordingStatus.unprocessed.title == "Not processed")
        #expect(RecordingStatus.queued.label == LibraryRecordingStatus.queued.title)
        #expect(RecordingStatus.needsAttention.label == LibraryRecordingStatus.failed.title)
        #expect(LibraryRecordingStatus.failed.title == "Needs attention")
    }
}
