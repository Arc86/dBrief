import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite struct LiveRecordingSessionRegistryTests {
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
