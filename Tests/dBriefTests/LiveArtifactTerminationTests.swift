import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor private final class TerminationWeakOwner {
    weak var value: LiveRecordingArtifactOwner?
    init(_ value: LiveRecordingArtifactOwner?) { self.value = value }
}

@MainActor @Suite struct LiveArtifactTerminationTests {
    @Test func cancelledDeadlineCallerAndRetiredRegistryCannotReleaseAHeldOriginalWriter() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .sourceTranscript)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0) })
        var entry: LiveRecordingSessionRegistry.Entry? = try registry.registerLegacy(f.identity)
        let original = TerminationWeakOwner(entry?.artifacts)
        registry.startPersistence(f.identity)
        try registry.captureDidClose(f.identity)
        let drain = Task { await LiveArtifactTerminationDrain.run(registry: registry, deadline: .milliseconds(100)) }
        do {
            try await gate.waitForArrival()
            drain.cancel()
            #expect(await drain.value == .timedOut)
            #expect(original.value?.failure != nil && original.value?.isDurable == false)
            try registry.retire(f.identity); entry = nil
            #expect(original.value != nil && registry.reservedPayloadBytes >= LiveRecordingArtifactOwner.reservationBytes)
            await gate.release()
            try await f.eventually { await MainActor.run { original.value == nil && registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes } }
            #expect(!FileManager.default.fileExists(atPath: f.session.appendingPathComponent("live-transcript.json").path))
        } catch { await gate.release(); _ = await drain.value; throw error }
    }

    @Test func oneHeldFailedOwnerDoesNotSkipFreezingOrSavingTheOtherOwner() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .sourceTranscript), fault = LiveArtifactFault(stage: .sourceTranscript)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0); try await fault.check($0) })
        let first = try registry.registerLegacy(f.identity)
        let next = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
        let second = try registry.registerLegacy(next)
        try first.artifacts.appendLegacy([.init(start: 0, end: 1, text: "First original owner")])
        try second.artifacts.appendLegacy([.init(start: 0, end: 1, text: "Other original owner")])
        registry.startPersistence(f.identity); registry.startPersistence(next)
        try registry.captureDidClose(f.identity); try registry.captureDidClose(next)
        let drain = Task { await LiveArtifactTerminationDrain.run(registry: registry, deadline: .seconds(3)) }
        do {
            try await gate.waitForArrival()
            #expect(throws: LiveArtifactError.terminating) { _ = try registry.registerLegacy(.init(recordingID: UUID(), captureSessionID: UUID())) }
            await gate.release()
            #expect(await drain.value == .failed)
            let healthy = first.artifacts.isDurable ? first : second
            let failed = first.artifacts.isDurable ? second : first
            #expect(healthy.artifacts.isDurable && !failed.artifacts.isDurable && failed.artifacts.failure != nil)
            let value = try #require(try await LiveSessionArtifactStore(identity: healthy.identity, rootURL: f.root).recover().appTranscript)
            #expect(value.captureClosed && value.legacy?.count == 1)
            try failed.artifacts.retry(); try await failed.artifacts.flush()
            #expect(failed.artifacts.isDurable)
        } catch { await gate.release(); _ = await drain.value; throw error }
    }

    @Test func readonlyRecoveredOwnerQuitPreservesExactSavedSourceAndHistoryBytes() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveTranscript(LiveTranscriptArtifact(identity: f.identity, revision: 5,
            legacy: [.init(.init(start: 0, end: 1, text: "Existing saved source"))], captureClosed: false))
        try await writer.saveChat(f.history("Older absent provenance"), revision: 7)
        let paths = [f.session.appendingPathComponent("live-transcript.json"), f.session.appendingPathComponent("chat.json")]
        let before = try paths.map { try Data(contentsOf: $0) }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        let entry = try #require(try await registry.resolve(recordingID: f.identity.recordingID))
        #expect(await LiveArtifactTerminationDrain.run(registry: registry, deadline: .seconds(3)) == .complete)
        #expect(entry.artifacts.acceptedRevision == 5 && entry.artifacts.acceptedChatRevision == 7 && entry.artifacts.isDurable)
        #expect(try paths.map { try Data(contentsOf: $0) } == before)
    }

    @Test func preAdmittedHydrationCannotInstallOrWriteAfterTheQuitCensus() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).saveChat(f.history("Original persisted history"), revision: 9)
        let path = f.session.appendingPathComponent("chat.json"), gate = LiveArtifactGate(stage: .ownerHydration)
        let before = try Data(contentsOf: path)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0) })
        let load = Task { try await registry.resolve(recordingID: f.identity.recordingID) }
        var drain: Task<LiveArtifactTerminationResult, Never>?
        do {
            try await gate.waitForArrival()
            let usage = registry.reservedPayloadBytes
            let operation = Task { await LiveArtifactTerminationDrain.run(registry: registry, deadline: .milliseconds(100)) }; drain = operation
            #expect(await operation.value == .timedOut && registry.reservedPayloadBytes == usage)
            await #expect(throws: LiveArtifactError.terminating) { _ = try await registry.resolve(recordingID: f.identity.recordingID) }
            await gate.release(); _ = try? await load.value
            try await f.eventually { await MainActor.run { registry.pendingLoads == 0 && registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes } }
            #expect(registry.entry(recordingID: f.identity.recordingID) == nil && !registry.isKnownDeleted(recordingID: f.identity.recordingID))
            #expect(try Data(contentsOf: path) == before)
        } catch { await gate.release(); _ = try? await load.value; _ = await drain?.value; throw error }
    }

    @Test func quitCensusIncludesTheResidentOriginalHiddenByAReplacementPhase() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        let original = try registry.registerLegacy(f.identity)
        registry.startPersistence(f.identity); try registry.captureDidClose(f.identity)
        try await original.artifacts.flush()
        let phase = try registry.beginReplacement(recordingID: f.identity.recordingID, audioURL: f.audio)
        #expect(registry.entry(recordingID: f.identity.recordingID) == nil)
        #expect(await LiveArtifactTerminationDrain.run(registry: registry, deadline: .seconds(3)) == .complete)
        #expect(throws: LiveArtifactError.terminating) { try original.artifacts.bind(to: f.audio) }
        // Already-admitted physical phase adoption can still retire its exact
        // original; the Quit latch grants no authority to a new replacement.
        try registry.adoptReplacement(phase, attemptID: UUID())
        #expect(!original.isValid && !registry.isKnownDeleted(recordingID: f.identity.recordingID))
    }
}
