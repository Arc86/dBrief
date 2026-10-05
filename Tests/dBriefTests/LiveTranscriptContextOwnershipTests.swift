import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite(.serialized)
struct LiveTranscriptContextOwnershipTests {
    private func context(_ f: LiveArtifactFixture, registry: LiveRecordingSessionRegistry, kind: String) async throws -> TranscriptContextSnapshot {
        let entry = kind == "native" ? try registry.register(f.identity) : try registry.registerLegacy(f.identity)
        if kind != "native" {
            try entry.artifacts.appendLegacy([.init(start: 0, end: 1, text: "Exact owned evidence", speaker: "You")])
            if kind == "final" {
                try registry.captureDidClose(f.identity)
                try entry.artifacts.publishFinal(.init(text: "Exact saved final"))
            }
        }
        let provider = TranscriptContextProvider.recording(recordingID: f.identity.recordingID, registry: registry,
            legacy: { .legacy(text: "Wrong fallback", recordingID: f.identity.recordingID, speakerLabels: []) })
        return try await provider.freeze().snapshot()
    }
    private func prepare(_ value: TranscriptContextSnapshot, answerID: UUID = UUID()) throws -> PreparedTranscriptChat {
        try TranscriptContextBuilder.build(snapshot: value,
            route: .init(engine: "fixture", endpointID: nil, provider: nil, origin: nil, model: nil),
            budget: .init(contextTokens: 8_192, outputTokens: 512, templateReserve: 256),
            language: .matchInput, question: "What is the evidence?", history: [], answerID: answerID)
    }

    @Test(arguments: ["legacy", "final", "native"])
    func escapedOwnedSnapshotRetainsItsOriginalChargeAfterFrozenAndEntryRelease(kind: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var value: TranscriptContextSnapshot? = try await context(f, registry: registry, kind: kind)
        let facts = try #require(value).source
        try registry.retire(f.identity)
        #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
        #expect(value?.source == facts)
        let next = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
        #expect(throws: LiveRecordingSessionRegistry.Failure.capacity) { _ = try registry.registerLegacy(next) }
        value = nil
        #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
        _ = try registry.registerLegacy(next)
    }

    @Test(arguments: ["legacy", "final"])
    func preparedPromptRetainsOwnedEvidenceAfterSnapshotRelease(kind: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var snapshot: TranscriptContextSnapshot? = try await context(f, registry: registry, kind: kind)
        var prompt: PreparedTranscriptChat? = try prepare(try #require(snapshot))
        snapshot = nil; try registry.retire(f.identity)
        #expect(prompt?.systemPrompt.contains("Exact") == true)
        #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
        prompt = nil
        #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
    }

    @Test func factsRemainEqualAndFrozenDuringGrowthButEqualityDoesNotGrantRetiredAuthority() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var snapshot: TranscriptContextSnapshot? = try await context(f, registry: registry, kind: "legacy")
        let facts = try #require(snapshot)
        let unowned = TranscriptContextSnapshot(source: facts.source, segments: facts.segments)
        #expect(facts == unowned)
        let answerID = UUID()
        var prompt: PreparedTranscriptChat? = try prepare(facts, answerID: answerID)
        let plainPrompt = PreparedTranscriptChat(systemPrompt: try #require(prompt).systemPrompt, userMessage: try #require(prompt).userMessage, basis: try #require(prompt).basis)
        #expect(prompt == plainPrompt)
        try registry.entry(recordingID: f.identity.recordingID)?.artifacts.appendLegacy([.init(start: 2, end: 3, text: "Later speech")])
        #expect(try prepare(facts, answerID: answerID).basis == prompt?.basis)
        #expect(facts.segments.map(\.text) == ["Exact owned evidence"])
        try registry.retire(f.identity)
        #expect(facts == unowned && prompt == plainPrompt)
        #expect(throws: CancellationError.self) { _ = try prepare(facts) }
        // The local `facts` still owns the original wrapper through this scope.
        snapshot = nil; prompt = nil
        #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
        withExtendedLifetime(facts) {}
    }

    @Test(arguments: [false, true])
    func heldActualDetachedBuildKeepsChargeAndRejectsRetirementBeforeActualReturn(cancel: Bool) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var snapshot: TranscriptContextSnapshot? = try await context(f, registry: registry, kind: "legacy")
        let gate = LiveArtifactGate(stage: .historyLoad)
        func build(_ value: TranscriptContextSnapshot) -> Task<PreparedTranscriptChat, any Error> {
            Task.detached {
                try await gate.enter(.historyLoad)
                defer { withExtendedLifetime(value) {} }
                return try TranscriptContextBuilder.build(snapshot: value,
                    route: .init(engine: "fixture", endpointID: nil, provider: nil, origin: nil, model: nil),
                    budget: .init(contextTokens: 8_192, outputTokens: 512, templateReserve: 256),
                    language: .matchInput, question: "Evidence", history: [], answerID: UUID())
            }
        }
        var work: Task<PreparedTranscriptChat, any Error>? = build(try #require(snapshot)); snapshot = nil
        do {
            try await gate.waitForArrival(); try registry.retire(f.identity)
            if cancel { work?.cancel() }
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            await gate.release()
            await #expect(throws: CancellationError.self) { _ = try await work?.value }
            work = nil
            #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
        } catch { work?.cancel(); await gate.release(); _ = try? await work?.value; throw error }
    }
}
