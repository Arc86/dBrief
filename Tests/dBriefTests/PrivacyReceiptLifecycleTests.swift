import Foundation
import Testing
@testable import dBrief

@Suite("Privacy receipt presentation and deletion")
struct PrivacyReceiptLifecycleTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-lifecycle-\(UUID())")
        var pending: URL { root.appendingPathComponent("pending") }
        var gaps: URL { root.appendingPathComponent("gaps") }
        var audio: URL { root.appendingPathComponent("meeting.m4a") }
        var receipt: URL { PrivacyReceiptStore.sidecarURL(for: audio) }
        func store() -> PrivacyReceiptStore { PrivacyReceiptStore(gapDirectoryURL: gaps, pendingDirectoryURL: pending) }
        func create() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
    private var operation: PrivacyOperation {
        .init(stage: .transcription, data: [.recordingAudio], destination: .local(provider: .whisper))
    }

    @Test func snapshotDoesNotCreateEvidenceAndReportsIndependentGapsAndUnreadableFiles() async throws {
        let f = Fixture(); try f.create(); defer { f.clean() }
        let store = f.store()
        let missing = await store.snapshot(at: [f.receipt])
        #expect(missing.heading == "Evidence unavailable")
        #expect(!missing.hasReceipt)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).isEmpty)
        await store.noteGap(at: f.receipt)
        let gap = await store.snapshot(at: [f.receipt])
        #expect(gap.heading == "Partial evidence")
        #expect(gap.attempts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.receipt.path))
        for bytes in [Data("private diagnostic".utf8), Data(#"{"version":999}"#.utf8)] {
            try bytes.write(to: f.receipt)
            let unreadable = await store.snapshot(at: [f.receipt])
            #expect(unreadable.hasUnreadableReceipt)
            #expect(unreadable.hasGaps)
            #expect(try Data(contentsOf: f.receipt) == bytes)
        }
    }

    @Test func failedBindRemainsVisibleAndCanBeDeletedAfterRestartWithoutOriginalScope() async throws {
        let f = Fixture(); try f.create(); defer { f.clean() }
        let store = f.store()
        let scope = RecordingPrivacyScope(recordingID: UUID(), store: store, pendingRootURL: f.pending)
        let context = await scope.context()
        let token = await PrivacyTrace.begin(operation, in: context)
        try Data("corrupt destination".utf8).write(to: f.receipt)
        await scope.bind(to: f.audio)
        let reopened = f.store()
        let view = await reopened.snapshot(at: [f.receipt])
        #expect(view.attempts.count == 1)
        #expect(view.attempts.first?.outcome == .started)
        #expect(view.hasUnreadableReceipt && view.hasGaps)
        let targets = await reopened.deletionTargets(for: f.audio)
        #expect(targets.contains { $0.resolvingSymlinksInPath() == scope.pendingReceiptURL.resolvingSymlinksInPath() })
        try await reopened.removeEvidence(at: targets)
        // Same-process late callback, plus a fresh store seeing a stale token.
        await PrivacyTrace.finish(token, outcome: .succeeded)
        try await f.store().finish(try #require(token?.id), outcome: .failed, at: scope.pendingReceiptURL)
        await f.store().noteGap(at: scope.pendingReceiptURL)
        #expect(try await f.store().begin(operation, runID: UUID(), at: scope.pendingReceiptURL) == nil)
        #expect(!FileManager.default.fileExists(atPath: scope.pendingReceiptURL.path))
        #expect(!FileManager.default.fileExists(atPath: f.receipt.path))
        #expect(await f.store().hasUnpersistedGap(at: scope.pendingReceiptURL) == false)
        #expect(await f.store().hasUnpersistedGap(at: f.receipt) == false)
    }

    @Test func boundTokensStaySuppressedButNewRecordingMayReuseFilename() async throws {
        let f = Fixture(); try f.create(); defer { f.clean() }
        let store = f.store()
        let old = RecordingPrivacyScope(recordingID: UUID(), store: store, pendingRootURL: f.pending)
        let token = await PrivacyTrace.begin(operation, in: await old.context())
        await old.bind(to: f.audio)
        let oldBytes = try Data(contentsOf: f.receipt)
        let targets = await store.deletionTargets(for: f.audio)
        try await store.removeEvidence(at: targets)
        await PrivacyTrace.finish(token, outcome: .succeeded)
        #expect(try await store.load(from: f.receipt) == nil)
        // Simulate interruption after durable suppression but before the old
        // receipt was removed. Reuse must finish cleanup, never merge owners.
        try oldBytes.write(to: f.receipt)
        let new = RecordingPrivacyScope(recordingID: UUID(), store: store, pendingRootURL: f.pending)
        try Data([1]).write(to: f.audio)
        try JSONEncoder().encode(["recordingID": new.recordingID.uuidString])
            .write(to: f.audio.deletingPathExtension().appendingPathExtension("json"))
        let newToken = await PrivacyTrace.begin(operation, in: await new.context())
        await new.bind(to: f.audio)
        await PrivacyTrace.finish(newToken, outcome: .succeeded)
        await PrivacyTrace.finish(token, outcome: .failed)
        let receipt = try #require(try await store.load(from: f.receipt))
        #expect(receipt.attempts.count == 1)
        #expect(receipt.attempts.first?.id == newToken?.id)
        #expect(receipt.attempts.first?.outcome == .succeeded)
        #expect(!receipt.hasGaps)
    }

    @Test func cleanupFailurePreservesDurableSuppressionAndDoesNotRemoveUnexpectedDirectory() async throws {
        let f = Fixture(); try f.create(); defer { f.clean() }
        try FileManager.default.createDirectory(at: f.receipt, withIntermediateDirectories: true)
        let sentinel = f.receipt.appendingPathComponent("keep")
        try Data([7]).write(to: sentinel)
        await #expect(throws: (any Error).self) { try await f.store().removeEvidence(at: [f.receipt]) }
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(try await f.store().begin(operation, runID: UUID(), at: f.receipt) == nil)
        try FileManager.default.removeItem(at: f.receipt)
        try await f.store().removeEvidence(at: [f.receipt])
        await f.store().noteGap(at: f.receipt)
        #expect(await f.store().hasUnpersistedGap(at: f.receipt) == false)
    }

    @Test func snapshotCombinesCrashReplayWithoutDuplicatingOrConfirmingConflicts() async throws {
        let f = Fixture(); try f.create(); defer { f.clean() }
        let store = f.store()
        let id = try #require(try await store.begin(operation, runID: UUID(), at: f.receipt))
        let stale = f.root.appendingPathComponent("stale.privacy.json")
        try Data(contentsOf: f.receipt).write(to: stale)
        try await store.finish(id, outcome: .succeeded, at: f.receipt)
        let snapshot = await store.snapshot(at: [stale, f.receipt, f.receipt])
        #expect(snapshot.attempts.count == 1)
        #expect(snapshot.attempts.first?.isConfirmedSuccess == true)
        try await store.finish(id, outcome: .failed, at: stale)
        let conflicting = await store.snapshot(at: [stale, f.receipt])
        #expect(conflicting.hasGaps)
        #expect(conflicting.attempts.first?.outcome == .started)
        #expect(conflicting.attempts.first?.finishedAt == nil)
    }

    @Test func scratchDiscardUsesSuccessfulSessionRemovalButKeepsOfflineFinalizedEvidence() throws {
        let f = Fixture(); try f.create(); defer { f.clean() }
        let session = f.root.appendingPathComponent("removed-session")
        let capture = session.appendingPathComponent("capture")
        let track = session.appendingPathComponent("microphone.wav")
        #expect(PrivacyReceiptLifecycle.canRemoveDiscardedEvidence(audioURL: capture, finalized: false,
            knownFiles: [capture, track], removedSessionDirectory: session))
        #expect(!PrivacyReceiptLifecycle.canRemoveDiscardedEvidence(audioURL: capture, finalized: false,
            knownFiles: [capture, track], removedSessionDirectory: nil))
        #expect(!PrivacyReceiptLifecycle.canRemoveDiscardedEvidence(audioURL: capture, finalized: true,
            knownFiles: [capture, track], removedSessionDirectory: session))
        #expect(!PrivacyReceiptLifecycle.canRemoveDiscardedEvidence(audioURL: capture, finalized: false,
            knownFiles: [capture, f.audio], removedSessionDirectory: session))
    }

    @Test func retentionRetriesPrivateRemnantsAfterRestartWithoutAudioOrFinalReceipt() async throws {
        let f = Fixture(); try f.create(); defer { f.clean() }
        let store = f.store()
        let scope = RecordingPrivacyScope(recordingID: UUID(), store: store, pendingRootURL: f.pending)
        _ = await PrivacyTrace.begin(operation, in: await scope.context())
        let pendingBytes = try Data(contentsOf: scope.pendingReceiptURL)
        await scope.bind(to: f.audio)
        let binding = scope.pendingReceiptURL.appendingPathExtension("binding")
        let bindingBytes = try Data(contentsOf: binding)
        await store.noteGap(at: f.receipt)
        let gap = try #require(try FileManager.default.contentsOfDirectory(at: f.gaps, includingPropertiesForKeys: nil).first { $0.pathExtension == "gap" })
        let targets = await store.deletionTargets(for: f.audio)
        try await store.removeEvidence(at: targets)
        // Reproduce the durable state of interruption during cleanup: final
        // receipt/audio gone, private remnants left beside deletion markers.
        try pendingBytes.write(to: scope.pendingReceiptURL)
        try bindingBytes.write(to: binding)
        try Data([1]).write(to: gap)
        let reopened = f.store()
        let result = await RetentionCleanup.cleanupWithPrivacy(category: .recordings, olderThanDays: 7,
            in: [], store: reopened)
        #expect(result.privacyCleanupFailures == 0)
        for url in [scope.pendingReceiptURL, binding, gap] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(try await reopened.begin(operation, runID: UUID(), at: scope.pendingReceiptURL) == nil)
    }

    @Test func retentionRemovesEvidenceOnlyAfterAllAudioAndQueueProtectionAreGone() async throws {
        let f = Fixture(); try f.create(); defer { f.clean() }
        let store = f.store()
        let scope = RecordingPrivacyScope(recordingID: UUID(), store: store, pendingRootURL: f.pending)
        _ = await PrivacyTrace.begin(operation, in: await scope.context())
        await scope.bind(to: f.audio)
        try Data([1]).write(to: f.audio)
        let segment = f.root.appendingPathComponent("meeting_part01.m4a")
        try Data([1]).write(to: segment)
        let old = Date().addingTimeInterval(-30 * 86_400)
        try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: f.audio.path)
        _ = await RetentionCleanup.cleanupWithPrivacy(category: .recordings, olderThanDays: 7, in: [f.root], store: store)
        #expect(!FileManager.default.fileExists(atPath: f.audio.path))
        #expect(FileManager.default.fileExists(atPath: f.receipt.path))
        try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: segment.path)
        let queue = f.root.appendingPathComponent("meeting.queue.json")
        try Data([1]).write(to: queue)
        _ = await RetentionCleanup.cleanupWithPrivacy(category: .recordings, olderThanDays: 7, in: [f.root], store: store)
        #expect(FileManager.default.fileExists(atPath: segment.path))
        #expect(FileManager.default.fileExists(atPath: f.receipt.path))
        _ = await RetentionCleanup.cleanupWithPrivacy(category: .transcripts, olderThanDays: 0, in: [f.root], store: store)
        #expect(FileManager.default.fileExists(atPath: f.receipt.path))
        try FileManager.default.removeItem(at: queue)
        let result = await RetentionCleanup.cleanupWithPrivacy(category: .recordings, olderThanDays: 7, in: [f.root], store: store)
        #expect(result.privacyCleanupFailures == 0)
        #expect(!FileManager.default.fileExists(atPath: f.receipt.path))
        #expect(!FileManager.default.fileExists(atPath: segment.path))
        #expect(try await store.begin(operation, runID: UUID(), at: scope.pendingReceiptURL) == nil)
    }

    @Test func independentlyProcessedSegmentNeverDeletesSurvivingMasterEvidence() async throws {
        let f = Fixture(); try f.create(); defer { f.clean() }
        let store = f.store()
        try Data([1]).write(to: f.audio)
        _ = try await store.begin(operation, runID: UUID(), at: f.receipt)
        let segment = f.root.appendingPathComponent("meeting_part01.m4a")
        let segmentReceipt = PrivacyReceiptStore.sidecarURL(for: segment)
        // The segment audio was already removed, but its separate receipt remains.
        _ = try await store.begin(operation, runID: UUID(), at: segmentReceipt)
        _ = await RetentionCleanup.cleanupWithPrivacy(category: .recordings, olderThanDays: 7, in: [f.root], store: store)
        #expect(FileManager.default.fileExists(atPath: f.audio.path))
        #expect(FileManager.default.fileExists(atPath: f.receipt.path))
        #expect(!FileManager.default.fileExists(atPath: segmentReceipt.path))
    }

    @Test func lastSegmentCleanupFindsFailedBindParentAfterRestartWithoutFinalReceipt() async throws {
        let f = Fixture(); try f.create(); defer { f.clean() }
        let store = f.store()
        let scope = RecordingPrivacyScope(recordingID: UUID(), store: store, pendingRootURL: f.pending)
        _ = await PrivacyTrace.begin(operation, in: await scope.context())
        try Data("unreadable".utf8).write(to: f.receipt)
        await scope.bind(to: f.audio)
        try FileManager.default.removeItem(at: f.receipt)
        try Data([1]).write(to: f.audio)
        let segment = f.root.appendingPathComponent("meeting_part01.m4a")
        try Data([1]).write(to: segment)
        let old = Date().addingTimeInterval(-30 * 86_400)
        try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: f.audio.path)
        _ = await RetentionCleanup.cleanupWithPrivacy(category: .recordings, olderThanDays: 7, in: [f.root], store: store)
        #expect(!FileManager.default.fileExists(atPath: f.audio.path))
        #expect(FileManager.default.fileExists(atPath: scope.pendingReceiptURL.path))
        #expect(FileManager.default.fileExists(atPath: segment.path))
        try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: segment.path)
        let reopened = f.store()
        _ = await RetentionCleanup.cleanupWithPrivacy(category: .recordings, olderThanDays: 7, in: [f.root], store: reopened)
        #expect(!FileManager.default.fileExists(atPath: segment.path))
        #expect(!FileManager.default.fileExists(atPath: scope.pendingReceiptURL.path))
        #expect(await reopened.hasUnpersistedGap(at: f.receipt) == false)
        #expect(try await reopened.begin(operation, runID: UUID(), at: scope.pendingReceiptURL) == nil)
    }
}
