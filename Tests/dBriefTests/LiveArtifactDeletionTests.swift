import Foundation
import Testing
import dBriefWire
@testable import dBrief

extension LiveArtifactDurabilityTests {
@Suite("Live history deletion intent")
struct LiveArtifactDeletionTests {
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
