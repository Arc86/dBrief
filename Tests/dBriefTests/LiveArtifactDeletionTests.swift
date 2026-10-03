import Foundation
import Testing
import dBriefWire
@testable import dBrief

extension LiveArtifactDurabilityTests {
@Suite("Live history deletion intent")
struct LiveArtifactDeletionTests {
    @Test func failedTypedIntentLeavesTheProducerTokenAndHistoryActive() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let validity = RecordingDerivativeValidity(), fault = LiveArtifactFault(stage: .deletionIntent)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, validity: validity, beforeStage: { try await fault.check($0) })
        try await writer.saveChat(f.history("Retain after failed admission"), revision: 1)
        await #expect(throws: LiveArtifactFixtureFailure.injected) { _ = try await writer.commitDeletionIntent() }
        try validity.withValidResult {}
        #expect(try await writer.recover().chat?.messages.last?.content == "Retain after failed admission")
        try await writer.saveChat(f.history("Producer still accepts"), revision: 2)
    }

    @Test func versionOneIntentStillCleansAndRecordsCompletionBeforeAudioRemoval() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveChat(f.history("Old intent"), revision: 1)
        try await writer.bind(to: f.audio)
        _ = try await writer.commitDeletionIntent()
        let intentURL = f.session.appendingPathComponent("deletion.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: intentURL)) as? [String: Any])
        object["version"] = 1; object.removeValue(forKey: "intentID"); object.removeValue(forKey: "cleanupComplete")
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: intentURL)
        #expect(try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().deleted)
        try FileManager.default.removeItem(at: f.audio)
        try FileManager.default.removeItem(at: f.audio.deletingPathExtension().appendingPathExtension("json"))
        #expect(try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().deleted)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: intentURL)) as? [String: Any])
        #expect(saved["cleanupComplete"] as? Bool == true)
    }

    @Test(arguments: [false, true])
    func verifiedIntentRetiresContentWhileCleanupCanRetryWithTheRetiredToken(bound: Bool) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let validity = RecordingDerivativeValidity(), fault = LiveArtifactFault(stage: .deletionCleanup)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, validity: validity, beforeStage: { try await fault.check($0) })
        try await writer.saveChat(f.history("Keep until verified cleanup"), revision: 1)
        if bound { try await writer.bind(to: f.audio) }
        let receipt = try await writer.commitDeletionIntent()
        #expect(receipt.identity == f.identity)
        let history = bound ? f.audio.deletingPathExtension().appendingPathExtension("chat.json") : f.session.appendingPathComponent("chat.json")
        #expect(FileManager.default.fileExists(atPath: history.path))
        validity.invalidate()
        await #expect(throws: CancellationError.self) { try await writer.saveChat(f.history("Retired callback"), revision: 2) }
        await #expect(throws: CancellationError.self) { _ = try await writer.recover() }
        await #expect(throws: LiveArtifactFixtureFailure.injected) { try await writer.cleanupDeletion(receipt) }
        #expect(FileManager.default.fileExists(atPath: history.path))
        try await writer.cleanupDeletion(receipt)
        #expect(!FileManager.default.fileExists(atPath: history.path))
        try await writer.cleanupDeletion(receipt) // Exact receipt is idempotent after completion.
        #expect(try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().deleted)
    }

    @Test func heldCleanupKeepsItsExactReceiptAuthorityAfterProducerRetirement() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let validity = RecordingDerivativeValidity(), gate = LiveArtifactGate(stage: .deletionCleanup)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, validity: validity, beforeStage: { try await gate.enter($0) })
        try await writer.saveChat(f.history("Delete held owner"), revision: 1)
        try await writer.bind(to: f.audio)
        let receipt = try await writer.commitDeletionIntent()
        let cleanup = Task { try await writer.cleanupDeletion(receipt) }
        do {
            try await gate.waitForArrival()
            validity.invalidate()
            let claim = UUID()
            try RecordingResultMutation.claim(audioURL: f.audio, attemptID: claim)
            RecordingResultMutation.release(audioURL: f.audio, attemptID: claim)
            await gate.release()
            try await cleanup.value
            await #expect(throws: CancellationError.self) { try await writer.saveChat(f.history("Obsolete save"), revision: 2) }
            try FileManager.default.removeItem(at: f.audio)
            try FileManager.default.removeItem(at: f.audio.deletingPathExtension().appendingPathExtension("json"))
            #expect(try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().deleted)
        } catch { await gate.release(); _ = try? await cleanup.value; throw error }
    }

    @Test(arguments: [false, true])
    func aHeldSaveCannotResumeAfterItsSharedTokenAndReprocessingClaimRetire(bound: Bool) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let validity = RecordingDerivativeValidity(), gate = LiveArtifactGate(stage: bound ? .targetChat : .sourceChat, initiallyEnabled: false)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, validity: validity, beforeStage: { try await gate.enter($0) })
        try await writer.saveChat(f.history("Accepted before retirement"), revision: 1)
        if bound { try await writer.bind(to: f.audio) }
        await gate.arm()
        let late = Task { try await writer.saveChat(f.history("Must not republish"), revision: 2) }
        do {
            try await gate.waitForArrival()
            validity.invalidate()
            let claim = UUID()
            try RecordingResultMutation.claim(audioURL: f.audio, attemptID: claim)
            RecordingResultMutation.release(audioURL: f.audio, attemptID: claim)
            await gate.release()
            await #expect(throws: CancellationError.self) { try await late.value }
            let restored = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover()
            #expect(restored.chat?.messages.last?.content == "Accepted before retirement")
        } catch { await gate.release(); _ = try? await late.value; throw error }
    }

    @Test(arguments: ["identity", "generation", "intent", "version", "forged-completion"])
    func changedIntentCannotUseAnEarlierReceiptToRemoveArtifacts(kind: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveChat(f.history("Preserve conflict"), revision: 1)
        try await writer.bind(to: f.audio)
        let receipt = try await writer.commitDeletionIntent()
        let target = f.audio.deletingPathExtension().appendingPathExtension("chat.json")
        let before = try Data(contentsOf: target), intentURL = f.session.appendingPathComponent("deletion.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: intentURL)) as? [String: Any])
        switch kind {
        case "identity": object["identity"] = ["recordingID": UUID().uuidString, "captureSessionID": UUID().uuidString]
        case "generation": object["generation"] = UUID().uuidString
        case "intent": object["intentID"] = UUID().uuidString
        case "version": object["version"] = 99
        default: object["cleanupComplete"] = true
        }
        let changed = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try changed.write(to: intentURL)
        await #expect(throws: (any Error).self) { try await writer.cleanupDeletion(receipt) }
        #expect(try Data(contentsOf: target) == before)
        #expect(try Data(contentsOf: intentURL) == changed)
    }

    @Test func completedCleanupRemainsDeletedAfterMasterAndMetadataRemoval() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveChat(f.history("Delete before audio removal"), revision: 1)
        try await writer.bind(to: f.audio)
        try await writer.recordDeletionIntent()
        try FileManager.default.removeItem(at: f.audio)
        try FileManager.default.removeItem(at: f.audio.deletingPathExtension().appendingPathExtension("json"))
        let restart = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        #expect(try await restart.recover().deleted)
        await #expect(throws: LiveArtifactError.deleted) { try await restart.saveChat(f.history("Must not return"), revision: 2) }
    }

    @Test func failedIntentCannotRetireOrDestroyRecoverableHistory() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let fault = LiveArtifactFault(stage: .deletionIntent)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await fault.check($0) })
        try await writer.saveChat(f.history("Keep"), revision: 1)
        await #expect(throws: LiveArtifactFixtureFailure.injected) { try await writer.recordDeletionIntent() }
        #expect(try await writer.recover().chat?.messages.last?.content == "Keep")
        try await writer.saveChat(f.history("Still active"), revision: 2)
        #expect(try await writer.recover().chat?.messages.last?.content == "Still active")
    }

    @Test(arguments: [false, true])
    func restartAfterIntentCannotReplayOrRecreateDeletedHistory(bound: Bool) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveChat(f.history("Delete"), revision: 1)
        if bound { try await writer.bind(to: f.audio) }
        try await writer.recordDeletionIntent()
        let restart = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        let recovered = try await restart.recover()
        #expect(recovered.deleted && recovered.chat == nil && recovered.transcript == nil)
        await #expect(throws: LiveArtifactError.deleted) { try await restart.saveChat(f.history("Late callback"), revision: 2) }
        #expect(!FileManager.default.fileExists(atPath: f.session.appendingPathComponent("chat.json").path))
        if bound { #expect(!FileManager.default.fileExists(atPath: f.audio.deletingPathExtension().appendingPathExtension("chat.json").path)) }
    }

    @Test func aWriterFromBeforeTheDurableIntentCannotRecreateFiles() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let old = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await old.saveChat(f.history("Old owner"), revision: 1)
        try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recordDeletionIntent()
        await #expect(throws: LiveArtifactError.deleted) { try await old.saveChat(f.history("Late callback"), revision: 2) }
        #expect(!FileManager.default.fileExists(atPath: f.session.appendingPathComponent("chat.json").path))
    }

    @Test func restartCompletesCleanupAfterAnIntentWasDurable() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let fault = LiveArtifactFault(stage: .deletionCleanup)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await fault.check($0) })
        try await writer.saveChat(f.history("Delete"), revision: 1)
        await #expect(throws: LiveArtifactFixtureFailure.injected) { try await writer.recordDeletionIntent() }
        #expect(await writer.status().deleted)
        #expect(FileManager.default.fileExists(atPath: f.session.appendingPathComponent("chat.json").path))
        let recovered = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover()
        #expect(recovered.deleted && recovered.chat == nil)
        #expect(!FileManager.default.fileExists(atPath: f.session.appendingPathComponent("chat.json").path))
    }

    @Test func aHeldPromotionCannotCrossAnotherWritersDurableIntent() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .targetChat)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await gate.enter($0) })
        try await writer.saveChat(f.history("Delete during promotion"), revision: 1)
        let binding = Task { try await writer.bind(to: f.audio) }
        do {
            try await gate.waitForArrival()
            try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recordDeletionIntent()
            await gate.release()
            await #expect(throws: LiveArtifactError.deleted) { try await binding.value }
            #expect(!FileManager.default.fileExists(atPath: f.audio.deletingPathExtension().appendingPathExtension("chat.json").path))
            #expect(try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().deleted)
        } catch {
            binding.cancel(); await gate.release(); _ = try? await binding.value
            throw error
        }
    }
}
}
