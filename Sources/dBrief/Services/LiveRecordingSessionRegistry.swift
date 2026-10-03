import Foundation
import dBriefWire

@MainActor
final class LiveRecordingSessionRegistry {
    enum Failure: Error, Equatable { case identityConflict, retired }
    final class Entry {
        let identity: LiveSessionIdentity
        let store: LiveTranscriptStore
        let validity = RecordingDerivativeValidity()
        private(set) var captureClosed = false
        private(set) var isValid = true
        private(set) var coordinator: LiveCaptureSessionCoordinator?
        fileprivate init(identity: LiveSessionIdentity) {
            self.identity = identity; self.store = LiveTranscriptStore(identity: identity,validity: validity)
        }
        fileprivate func closeCapture() { captureClosed = true }
        fileprivate func invalidate() {
            isValid = false; validity.invalidate()
            let retired = coordinator; coordinator = nil
            Task { await retired?.retire() }
        }
        fileprivate func install(_ owner: LiveCaptureSessionCoordinator) throws {
            guard !captureClosed, owner.belongs(to: identity,store: store,validity: validity),
                  coordinator == nil || coordinator === owner else { throw Failure.identityConflict }
            coordinator = owner
        }
    }
    private var entries: [UUID: Entry] = [:]
    private var captureOwners: [UUID: UUID] = [:]
    private var retiredRecordings: Set<UUID> = []

    func register(_ identity: LiveSessionIdentity) throws -> Entry {
        guard !retiredRecordings.contains(identity.recordingID) else { throw Failure.retired }
        if let entry = entries[identity.recordingID] {
            guard entry.identity == identity else { throw Failure.identityConflict }
            return entry
        }
        guard captureOwners[identity.captureSessionID] == nil else { throw Failure.identityConflict }
        let entry = Entry(identity: identity)
        entries[identity.recordingID] = entry; captureOwners[identity.captureSessionID] = identity.recordingID
        return entry
    }

    func entry(recordingID: UUID) -> Entry? { entries[recordingID] }
    func isRetired(recordingID: UUID) -> Bool { retiredRecordings.contains(recordingID) }
    func entry(identity: LiveSessionIdentity) -> Entry? {
        guard let entry = entries[identity.recordingID], entry.identity == identity else { return nil }
        return entry
    }

    func captureDidClose(_ identity: LiveSessionIdentity) throws { try owned(identity).closeCapture() }
    func install(_ coordinator: LiveCaptureSessionCoordinator, for identity: LiveSessionIdentity) throws { try owned(identity).install(coordinator) }

    /// Retire the owner synchronously before asynchronous artifact cleanup. This
    /// removes lookup and tombstones identities without destroying other history.
    func retire(_ identity: LiveSessionIdentity) throws {
        let entry = try owned(identity)
        entry.invalidate(); entries[identity.recordingID] = nil
        retiredRecordings.insert(identity.recordingID)
        // Retain the capture namespace tombstone; a late attach cannot alias it.
    }

    private func owned(_ identity: LiveSessionIdentity) throws -> Entry {
        guard !retiredRecordings.contains(identity.recordingID) else { throw Failure.retired }
        guard let entry = entry(identity: identity) else { throw Failure.identityConflict }
        return entry
    }
}
