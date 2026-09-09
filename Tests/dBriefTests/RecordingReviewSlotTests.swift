import Foundation
import Testing
@testable import dBrief

@Suite("Recording review handoffs") @MainActor
struct RecordingReviewSlotTests {
    @MainActor private final class Harness {
        let state = AppState()
        let action = PostRecordingActionState()
        var captureBusy = false
        var maintenance = false
        var waiter: CheckedContinuation<Void, Never>?
        lazy var slot = RecordingReviewSlot(appState: state, action: action,
            captureBusy: { self.captureBusy }, maintenance: { self.maintenance })
        func suspend() async { await withCheckedContinuation { waiter = $0 } }
        func release() { waiter?.resume(); waiter = nil }
        func recording() -> Recording { .init(fileURL: URL(fileURLWithPath: "/tmp/synthetic-review-\(UUID()).caf")) }
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test func inFlightImportCannotReplaceReviewWhileSaveOwnsIt() async throws {
        let h = Harness(), original = h.recording(), imported = h.recording()
        h.state.currentRecording = original; h.state.showPostRecordingSheet = true
        let pendingImport = try #require(h.slot.snapshotForImport())
        let token = try #require(h.action.begin(recordingID: original.id, action: .skip))
        let saving = Task {
            await h.suspend() // The finalizer has not returned yet.
            return h.slot.dismiss(for: original, actionToken: token)
        }
        try await wait { h.waiter != nil }
        #expect(h.slot.snapshotForImport() == nil)
        #expect(!h.slot.acceptImport(imported, replacing: pendingImport))
        #expect(h.state.currentRecording === original && h.state.showPostRecordingSheet)
        h.release()
        #expect(await saving.value)
        h.action.finish(token: token)
        #expect(!h.state.showPostRecordingSheet && h.state.currentRecording === original)
    }

    @Test(arguments: ["capture", "termination", "maintenance", "saving"])
    func importedResultRechecksAdmissionAfterPreparation(reason: String) async throws {
        let h = Harness(), original = h.recording(), imported = h.recording()
        h.state.currentRecording = original; h.state.showPostRecordingSheet = true
        let snapshot = try #require(h.slot.snapshotForImport())
        let preparing = Task { await h.suspend(); return h.slot.acceptImport(imported, replacing: snapshot) }
        try await wait { h.waiter != nil }
        switch reason {
        case "capture", "termination": h.captureBusy = true
        case "maintenance": h.maintenance = true
        default: _ = h.action.begin(recordingID: original.id, action: .delete)
        }
        h.release()
        #expect(await preparing.value == false)
        #expect(h.state.currentRecording === original && h.state.showPostRecordingSheet)
    }

    @Test func delayedBackgroundPreparationCannotDismissAnotherCapturesReview() async throws {
        let h = Harness(), background = h.recording(), capture = h.recording()
        h.state.currentRecording = background
        let prepared = Task { await h.suspend(); return h.slot.dismiss(for: background) }
        try await wait { h.waiter != nil }
        h.captureBusy = true; h.state.currentRecording = capture; h.state.recordingState = .recording
        h.captureBusy = false; h.state.recordingState = .idle; h.state.showPostRecordingSheet = true
        h.release()
        #expect(await prepared.value == false)
        #expect(h.state.showPostRecordingSheet && h.state.currentRecording === capture)
    }

    @Test func staleActionCannotDismissOrReportFailureAgainstReplacement() throws {
        let h = Harness(), original = h.recording(), replacement = h.recording()
        h.state.currentRecording = original; h.state.showPostRecordingSheet = true
        let old = try #require(h.action.begin(recordingID: original.id, action: .skip))
        h.state.currentRecording = replacement
        #expect(!h.slot.ownsAction(for: original, token: old))
        #expect(!h.slot.dismiss(for: original, actionToken: old))
        #expect(h.state.showPostRecordingSheet)
        h.action.finish(token: old)
        let current = try #require(h.action.begin(recordingID: replacement.id, action: .process))
        #expect(!h.slot.dismiss(for: replacement, actionToken: old))
        #expect(h.slot.dismiss(for: replacement, actionToken: current))
    }

    @Test func legitimateImportAndOwnRecordingProcessingKeepTheirExistingHandoffs() throws {
        let h = Harness(), imported = h.recording()
        let snapshot = try #require(h.slot.snapshotForImport())
        #expect(h.slot.acceptImport(imported, replacing: snapshot))
        #expect(h.state.currentRecording === imported && h.state.showPostRecordingSheet)
        #expect(h.slot.dismiss(for: imported))
        #expect(!h.state.showPostRecordingSheet)
    }
}
