import Foundation
import Testing
@testable import dBrief

@Suite("Recording privacy scope lifecycle")
struct RecordingPrivacyScopeTests {
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-scope-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private var operation: PrivacyOperation {
        .init(stage: .finalization, data: [.recordingAudio], destination: .local(provider: .fileSystem))
    }

    @Test func inFlightTokensFinishAfterFinalAudioLocationIsKnown() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps"))
        let scope = RecordingPrivacyScope(recordingID: UUID(), store: store, pendingRootURL: folder.appendingPathComponent("pending"))
        let context = await scope.context()
        let token = await PrivacyTrace.$context.withValue(context) { await PrivacyTrace.begin(operation) }
        let audio = folder.appendingPathComponent("final-audio.m4a")
        await scope.bind(to: audio)
        await PrivacyTrace.finish(token, outcome: .succeeded)
        let receipt = try #require(try await store.load(from: PrivacyReceiptStore.sidecarURL(for: audio)))
        #expect(receipt.attempts.count == 1)
        #expect(receipt.attempts[0].outcome == .succeeded)
        #expect(receipt.attempts[0].runID == context.runID)
        #expect(!FileManager.default.fileExists(atPath: scope.pendingReceiptURL.path))
    }

    @Test func repeatedMigrationAfterInterruptionDoesNotDuplicateOrDowngradeEvidence() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("pending.json")
        let target = folder.appendingPathComponent("final.json")
        let store = PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps"))
        let id = try #require(try await store.begin(operation, runID: UUID(), at: source))
        let staleSource = try Data(contentsOf: source)
        try await store.transfer(from: source, to: target)
        try await store.finish(id, outcome: .succeeded, at: target)
        // Simulate a crash after installing the final sidecar but before removing
        // the old source. A fresh store has no in-memory aliases.
        try staleSource.write(to: source)
        let reopened = PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps"))
        try await reopened.transfer(from: source, to: target)
        let receipt = try #require(try await reopened.load(from: target))
        #expect(receipt.attempts.count == 1)
        #expect(receipt.attempts[0].outcome == .succeeded)
        #expect(!receipt.hasGaps)
    }

    @Test func failedBindingPreservesEvidenceAndMarksDestinationGap() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps"))
        let scope = RecordingPrivacyScope(recordingID: UUID(), store: store, pendingRootURL: folder.appendingPathComponent("pending"))
        let context = await scope.context()
        _ = try await store.begin(operation, runID: context.runID, at: context.receiptURL)
        let audio = folder.appendingPathComponent("final.m4a")
        let target = PrivacyReceiptStore.sidecarURL(for: audio)
        try Data("unreadable existing receipt".utf8).write(to: target)
        await scope.bind(to: audio)
        #expect(try String(contentsOf: target, encoding: .utf8) == "unreadable existing receipt")
        #expect(try await store.load(from: scope.pendingReceiptURL)?.attempts.count == 1)
        #expect(await store.hasUnpersistedGap(at: target))
    }

    @Test func mergeRetainsSeparateRunsAndPendingGapEvidence() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("pending.json"), target = folder.appendingPathComponent("final.json")
        let store = PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps"))
        let firstRun = UUID(), secondRun = UUID()
        _ = try await store.begin(operation, runID: firstRun, at: source)
        _ = try await store.begin(operation, runID: secondRun, at: target)
        await store.noteGap(at: source)
        try await store.transfer(from: source, to: target)
        let receipt = try #require(try await store.load(from: target))
        #expect(Set(receipt.attempts.map(\.runID)) == [firstRun, secondRun])
        #expect(receipt.hasGaps)
        // The old context follows the transferred scope for future work too.
        _ = try await store.begin(operation, runID: firstRun, at: source)
        #expect(try await store.load(from: target)?.attempts.count == 3)
    }
}
