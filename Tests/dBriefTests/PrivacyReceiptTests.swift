import Foundation
import Testing
@testable import dBrief

@Suite("Privacy receipt evidence")
struct PrivacyReceiptTests {
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-receipt-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("meeting.privacy.json")
    }
    private var operation: PrivacyOperation {
        .init(stage: .transcription, data: [.recordingAudio],
              destination: .remote(url: URL(string: "https://user:password@EXAMPLE.com/private/path?key=secret#fragment")!,
                                   provider: .openAICompatible, model: "whisper-1"))
    }

    @Test func persistsOnlyAllowedMetadataAndPrivatePermissions() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PrivacyReceiptStore()
        let id = try #require(try await store.begin(operation, runID: UUID(), at: url))
        try await store.finish(id, outcome: .succeeded, at: url)
        let receipt = try #require(try await store.load(from: url))
        #expect(receipt.attempts.first?.operation.destination.hostname == "example.com")
        #expect(receipt.attempts.first?.outcome == .succeeded)
        let text = try String(contentsOf: url, encoding: .utf8)
        for secret in ["password", "private/path", "key=secret", "fragment", "https://", "user:"] {
            #expect(!text.contains(secret))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(PrivacyDestination.remote(url: URL(string: "https://example.com")!, provider: .custom,
            model: "secret prompt\nAuthorization: Bearer abc").model == nil)
    }

    @Test func interruptionRemainsUncertainAfterRestart() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try await PrivacyReceiptStore().begin(operation, runID: UUID(), at: url)
        let receipt = try #require(try await PrivacyReceiptStore().load(from: url))
        #expect(receipt.attempts.count == 1)
        #expect(receipt.attempts[0].outcome == .started)
        #expect(receipt.attempts[0].finishedAt == nil)
        #expect(!receipt.attempts[0].isConfirmedSuccess)
    }

    @Test func concurrentAttemptsRemainDistinctAndFinishIdempotently() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PrivacyReceiptStore()
        let run = UUID()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    let id = try #require(try await store.begin(operation, runID: run, at: url))
                    try await store.finish(id, outcome: .failed, at: url)
                    try await store.finish(id, outcome: .failed, at: url)
                }
            }
            try await group.waitForAll()
        }
        let receipt = try #require(try await store.load(from: url))
        #expect(receipt.attempts.count == 24)
        #expect(Set(receipt.attempts.map(\.id)).count == 24)
        #expect(receipt.attempts.allSatisfy { $0.runID == run && $0.outcome == .failed })
        let id = try #require(receipt.attempts.first?.id)
        await #expect(throws: (any Error).self) { try await store.finish(id, outcome: .succeeded, at: url) }
    }

    @Test func corruptFutureAndSymbolicLinkReceiptsAreNeverOverwritten() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PrivacyReceiptStore()
        for bytes in [Data("broken".utf8), Data(#"{"version":99}"#.utf8)] {
            try bytes.write(to: url)
            await #expect(throws: (any Error).self) { _ = try await store.begin(operation, runID: UUID(), at: url) }
            #expect(try Data(contentsOf: url) == bytes)
        }
        let target = url.deletingLastPathComponent().appendingPathComponent("untouched.json")
        try Data("private".utf8).write(to: target)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        await #expect(throws: (any Error).self) { _ = try await store.begin(operation, runID: UUID(), at: url) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "private")
        try FileManager.default.removeItem(at: target)
        // A dangling link is unsafe too; fileExists alone cannot detect it.
        await #expect(throws: (any Error).self) { _ = try await store.begin(operation, runID: UUID(), at: url) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)
    }

    @Test func boundedHistoryReportsMissingEvidenceAndStillFinishesRetainedAttempts() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PrivacyReceiptStore(maximumAttempts: 1)
        let id = try #require(try await store.begin(operation, runID: UUID(), at: url))
        #expect(try await store.begin(operation, runID: UUID(), at: url) == nil)
        try await store.finish(id, outcome: .cancelled, at: url)
        let receipt = try #require(try await store.load(from: url))
        #expect(receipt.attempts.count == 1)
        #expect(receipt.omittedAttempts == 1)
        #expect(receipt.hasGaps)
        #expect(receipt.attempts[0].outcome == .cancelled)
    }

    @Test func tracingFailureDoesNotRunAsEvidenceOfSuccess() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PrivacyReceiptStore(gapDirectoryURL: url.deletingLastPathComponent().appendingPathComponent("gaps"))
        let context = PrivacyTrace.Context(receiptURL: url, store: store)
        // A blocked destination cannot be written. The operation itself remains
        // the caller's responsibility; tracing records an explicit evidence gap.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let token = await PrivacyTrace.$context.withValue(context) { await PrivacyTrace.begin(operation) }
        #expect(token == nil)
        #expect(await store.hasUnpersistedGap(at: url))
        try FileManager.default.removeItem(at: url)
        _ = try await store.begin(operation, runID: UUID(), at: url)
        #expect(try await store.load(from: url)?.hasGaps == true)
    }

    @Test func failedRemoteEvidenceSurvivesRestartWithAnOlderLocalReceipt() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gaps = url.deletingLastPathComponent().appendingPathComponent("independent-gap-store")
        let store = PrivacyReceiptStore(gapDirectoryURL: gaps)
        let local = PrivacyOperation(stage: .transcription, data: [.recordingAudio], destination: .local(provider: .whisper))
        let id = try #require(try await store.begin(local, runID: UUID(), at: url))
        try await store.finish(id, outcome: .succeeded, at: url)
        let backup = url.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: url, to: backup)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let context = PrivacyTrace.Context(receiptURL: url, store: store)
        #expect(await PrivacyTrace.$context.withValue(context) { await PrivacyTrace.begin(operation) } == nil)
        let marker = try #require(FileManager.default.contentsOfDirectory(at: gaps, includingPropertiesForKeys: nil).first)
        #expect(marker.deletingPathExtension().lastPathComponent.count == 64)
        #expect(try Data(contentsOf: marker) == Data([1]))
        let markerAttributes = try FileManager.default.attributesOfItem(atPath: marker.path)
        #expect((markerAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: backup, to: url)
        let reopened = PrivacyReceiptStore(gapDirectoryURL: gaps)
        let receipt = try #require(try await reopened.load(from: url))
        #expect(receipt.hasGaps)
        #expect(receipt.attempts.count == 1)
        #expect(receipt.attempts[0].operation.destination.location == .local)
        _ = try await reopened.begin(operation, runID: UUID(), at: url)
        #expect(try await PrivacyReceiptStore(gapDirectoryURL: gaps).load(from: url)?.hasGaps == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: gaps.path).isEmpty)
    }

    @Test func taskContextsKeepRecordingsSeparateAndDoNotLeakAfterScope() async throws {
        let first = try fixture(), second = try fixture()
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let store = PrivacyReceiptStore()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for url in [first, second] {
                group.addTask {
                    let context = PrivacyTrace.Context(receiptURL: url, store: store)
                    await PrivacyTrace.$context.withValue(context) {
                        let token = await PrivacyTrace.begin(operation)
                        await PrivacyTrace.finish(token, outcome: .succeeded)
                    }
                }
            }
            try await group.waitForAll()
        }
        let a = try #require(try await store.load(from: first))
        let b = try #require(try await store.load(from: second))
        #expect(a.attempts.count == 1 && b.attempts.count == 1)
        #expect(a.attempts[0].runID != b.attempts[0].runID)
        #expect(await PrivacyTrace.begin(operation) == nil)
    }
}
