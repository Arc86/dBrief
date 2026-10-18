import Foundation
import Testing
@testable import dBrief

/// Reprocess attempts showed in the menu panel's Queue & Recovery but never in the
/// library's Queued / Interrupted or Needs Attention views.
@Suite struct ReprocessWorkItemsTests {
    private let audio = URL(fileURLWithPath: "/tmp/work/2026-10-17_0930_weekly-sync.m4a")

    @Test func queuedAndStoppedAttemptsAppearInTheMatchingView() {
        let queued = LibraryWorkItem.ReprocessFacts(id: UUID(), audioURL: audio, status: .queued, message: nil, updatedAt: .now)
        let stopped = LibraryWorkItem.ReprocessFacts(id: UUID(), audioURL: audio, status: .stopped,
                                                     message: "Interrupted reprocessing", updatedAt: .now)
        let waiting = LibraryWorkItem.reprocessing([queued, stopped], view: .queuedInterrupted, activeAttemptID: nil)
        #expect(waiting.map(\.recoveryID) == [queued.id])
        #expect(waiting.first?.target == .reprocess && waiting.first?.status == "Reprocess queued")
        let attention = LibraryWorkItem.reprocessing([queued, stopped], view: .failedJobs, activeAttemptID: nil)
        #expect(attention.map(\.recoveryID) == [stopped.id])
        #expect(attention.first?.failed == true && attention.first?.status == "Interrupted reprocessing")
    }

    @Test func theRunningAttemptIsNotListed() {
        let queued = LibraryWorkItem.ReprocessFacts(id: UUID(), audioURL: audio, status: .queued, message: nil, updatedAt: .now)
        #expect(LibraryWorkItem.reprocessing([queued], view: .queuedInterrupted, activeAttemptID: queued.id).isEmpty)
        #expect(LibraryWorkItem.reprocessing([queued], view: .all, activeAttemptID: nil).isEmpty)
    }
}
