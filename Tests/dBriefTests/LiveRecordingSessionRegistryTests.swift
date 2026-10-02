import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite struct LiveRecordingSessionRegistryTests {
    @Test func onlyTheExactCoordinatorStoreAndValidityOwnerCanAttachAndRemainAfterCapture() async throws {
        let registry = LiveRecordingSessionRegistry(), identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
        let entry = try registry.register(identity)
        let input = LiveSessionBegin(identity: identity,configuration: .init(language: .auto,modelDirectory: "/fixture"),epochs: [
            .init(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)])
        let transport = LiveASRTransport(begin: { _ in AsyncThrowingStream { _ in } },command: { _ in .accepted },deadline: { _ in },shutdown: {})
        let owner = LiveCaptureSessionCoordinator(input: input,store: entry.store,transport: transport,validity: entry.validity)
        try registry.install(owner,for: identity)
        #expect(entry.coordinator === owner)
        try registry.install(owner,for: identity)
        let wrongStore = LiveCaptureSessionCoordinator(input: input,store: LiveTranscriptStore(identity: identity),transport: transport,validity: entry.validity)
        #expect(throws: LiveRecordingSessionRegistry.Failure.identityConflict) { try registry.install(wrongStore,for: identity) }
        let wrongGuard = LiveCaptureSessionCoordinator(input: input,store: entry.store,transport: transport,validity: RecordingDerivativeValidity())
        #expect(throws: LiveRecordingSessionRegistry.Failure.identityConflict) { try registry.install(wrongGuard,for: identity) }
        try registry.captureDidClose(identity)
        #expect(registry.entry(identity: identity)?.coordinator === owner)
        try registry.retire(identity)
        #expect(entry.coordinator == nil && registry.entry(identity: identity) == nil)
    }

    @Test func synchronousRetirementPreventsAllLateStoreMutationsEvenBeforeActorCleanupRuns() async throws {
        let registry = LiveRecordingSessionRegistry(), f = LiveTranscriptFixture(), entry = try registry.register(f.identity), epoch = f.epoch()
        #expect(await entry.store.beginEpoch(owner: f.identity,epoch: epoch) == .accepted)
        #expect(await entry.store.admit(f.event(epoch,0,f.progress(1))) == .accepted)
        #expect(await entry.store.admit(f.event(epoch,1,.partial(.init(epochID: epoch.id,source: epoch.source,revision: 0,samples: .init(start: 0,end: 16000),text: "Pending")))) == .accepted)
        let frozen = await entry.store.projection()
        try registry.retire(f.identity)
        #expect(await entry.store.admit(f.event(epoch,2,.committed(f.segment(epoch,0,0,1)))) == .rejected(.closed))
        #expect(await entry.store.beginEpoch(owner: f.identity,epoch: f.epoch()) == .rejected(.closed))
        #expect(await entry.store.registerDiarizer(owner: f.identity,source: epoch.source,contextID: UUID()) == .rejected(.closed))
        #expect(await entry.store.clearPartials(owner: f.identity) == .rejected(.closed))
        #expect(await entry.store.close(owner: f.identity) == .rejected(.closed))
        #expect(await entry.store.publishFinal(.init(identity: f.identity,id: UUID(),revision: 1,segments: [])) == .rejected(.closed))
        #expect(await entry.store.projection() == frozen)
    }

    @Test func captureClosureKeepsTheSameRecordingOwnedStoreForPostProcessing() async throws {
        let registry = LiveRecordingSessionRegistry(), identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
        let entry = try registry.register(identity)
        #expect(try registry.register(identity) === entry)
        try registry.captureDidClose(identity)
        #expect(entry.captureClosed && entry.isValid)
        #expect(registry.entry(recordingID: identity.recordingID) === entry)
        #expect(registry.entry(identity: identity)?.store === entry.store)
    }
    @Test func retiredOwnersCannotReappearOrInvalidateAnotherCapture() throws {
        let registry = LiveRecordingSessionRegistry(), first = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
        let entry = try registry.register(first)
        let second = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID()), next = try registry.register(second)
        try registry.retire(first)
        #expect(!entry.isValid && registry.entry(recordingID: first.recordingID) == nil)
        #expect(throws: CancellationError.self) { try entry.validity.withValidResult { true } }
        #expect(try next.validity.withValidResult { true })
        #expect(registry.entry(identity: second) === next && next.isValid)
        #expect(throws: LiveRecordingSessionRegistry.Failure.retired) { try registry.register(first) }
        #expect(throws: LiveRecordingSessionRegistry.Failure.retired) { try registry.captureDidClose(first) }
        #expect(registry.entry(identity: second) === next)
    }
    @Test func recordingAndCaptureIdentitiesCannotBeAliased() throws {
        let registry = LiveRecordingSessionRegistry(), first = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
        let entry = try registry.register(first)
        let otherCapture = LiveSessionIdentity(recordingID: first.recordingID,captureSessionID: UUID())
        #expect(throws: LiveRecordingSessionRegistry.Failure.identityConflict) { try registry.register(otherCapture) }
        let otherRecording = LiveSessionIdentity(recordingID: UUID(),captureSessionID: first.captureSessionID)
        #expect(throws: LiveRecordingSessionRegistry.Failure.identityConflict) { try registry.register(otherRecording) }
        #expect(throws: LiveRecordingSessionRegistry.Failure.identityConflict) { try registry.retire(otherCapture) }
        #expect(registry.entry(identity: first) === entry && entry.isValid)
        #expect(registry.entry(identity: otherCapture) == nil)
    }
}
