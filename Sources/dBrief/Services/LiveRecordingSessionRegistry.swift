import Foundation
import dBriefWire

@MainActor
final class LiveRecordingSessionRegistry {
    enum Failure: Error, Equatable { case identityConflict, retired, capacity, unavailable }
    @MainActor final class Entry {
        let identity: LiveSessionIdentity
        let store: LiveTranscriptStore
        let validity = RecordingDerivativeValidity()
        let artifacts: LiveRecordingArtifactOwner
        let savedTranscriptOrder = LiveSavedTranscriptOrder()
        let richWriteValidity = RecordingDerivativeValidity()
        private(set) var richDeletionAdmission = RecordingDerivativeValidity()
        func sealRichWritesForDeletion() { richDeletionAdmission.invalidate() }
        func resumeRichWritesAfterFailedIntent() { if isValid { richDeletionAdmission = .init() } }
        private(set) var captureClosed = false
        private(set) var isValid = true
        private(set) var coordinator: LiveCaptureSessionCoordinator?
        fileprivate init(identity: LiveSessionIdentity, native: Bool, root: URL,
                         reservation: LiveRecordingPayloadBudget.Lease,
                         beforeStage: @escaping @Sendable (LiveArtifactStage) async throws -> Void,
                         afterCheckpoint: @escaping @Sendable () async -> Void) {
            self.identity = identity
            self.store = LiveTranscriptStore(identity: identity,validity: validity,
                retainedEvidenceLimit: LiveRecordingArtifactOwner.evidenceLimit, payloadReservation: reservation)
            artifacts = LiveRecordingArtifactOwner(identity: identity, store: store, validity: validity,
                native: native, rootURL: root, payloadReservation: reservation, beforeStage: beforeStage, afterCheckpoint: afterCheckpoint)
        }
        fileprivate func closeCapture() { captureClosed = true; artifacts.closeCapture() }
        fileprivate func invalidate() {
            isValid = false; validity.invalidate()
            richWriteValidity.invalidate()
            richDeletionAdmission.invalidate()
            artifacts.retire()
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
    private struct DeletionTicket {
        let entry: Entry
        let receipt: LiveSessionArtifactStore.DeletionReceipt
    }
    private var deletions: [UUID: DeletionTicket] = [:]
    private var captureOwners: [UUID: UUID] = [:]
    private var retiredRecordings: Set<UUID> = []
    private var unavailableRecordings: Set<UUID> = []
    private let artifactRoot: URL
    private let ownerLimit: Int
    private let beforeStage: @Sendable (LiveArtifactStage) async throws -> Void
    private let afterCheckpoint: @Sendable () async -> Void
    private let budget: LiveRecordingPayloadBudget
    var reservedPayloadBytes: Int { budget.reservedBytes }
    func reserveDeletionMaintenance() throws -> LiveRecordingPayloadBudget.Lease { try budget.reserveMaintenance() }
    func hasPendingDeletion(recordingID: UUID) -> Bool { deletions[recordingID] != nil }
    init(artifactRoot: URL = AppSupportPaths.subdirectory("LiveSessions"), ownerLimit: Int = 8,
         beforeStage: @escaping @Sendable (LiveArtifactStage) async throws -> Void = { _ in },
         afterCheckpoint: @escaping @Sendable () async -> Void = {}) {
        self.artifactRoot = artifactRoot; self.ownerLimit = min(8, max(1, ownerLimit)); self.beforeStage = beforeStage
        self.afterCheckpoint = afterCheckpoint
        budget = LiveRecordingPayloadBudget(ownerLimit: ownerLimit)
    }

    func register(_ identity: LiveSessionIdentity) throws -> Entry {
        try register(identity, native: true)
    }
    func registerLegacy(_ identity: LiveSessionIdentity) throws -> Entry { try register(identity, native: false) }
    func startPersistence(_ identity: LiveSessionIdentity) { entry(identity: identity)?.artifacts.start() }
    func owns(recordingID: UUID) -> Bool { captureOwners.values.contains(recordingID) }
    func noteUnavailable(_ identity: LiveSessionIdentity) {
        guard entries[identity.recordingID] == nil, captureOwners[identity.captureSessionID] == nil else { return }
        captureOwners[identity.captureSessionID] = identity.recordingID
        unavailableRecordings.insert(identity.recordingID)
    }
    private func register(_ identity: LiveSessionIdentity, native: Bool) throws -> Entry {
        guard !retiredRecordings.contains(identity.recordingID) else { throw Failure.retired }
        guard !unavailableRecordings.contains(identity.recordingID) else { throw Failure.unavailable }
        if let entry = entries[identity.recordingID] {
            guard entry.identity == identity, entry.artifacts.isNative == native else { throw Failure.identityConflict }
            return entry
        }
        guard captureOwners[identity.captureSessionID] == nil else { throw Failure.identityConflict }
        if !budget.canReserve { evictOneDurableOwner() }
        guard entries.count < ownerLimit else { throw Failure.capacity }
        let reservation = try budget.reserve()
        let entry = Entry(identity: identity, native: native, root: artifactRoot, reservation: reservation,
            beforeStage: beforeStage, afterCheckpoint: afterCheckpoint)
        entries[identity.recordingID] = entry; captureOwners[identity.captureSessionID] = identity.recordingID
        return entry
    }
    private func evictOneDurableOwner() {
        guard let evictable = entries.values.first(where: { $0.artifacts.canEvict }) else { return }
        evictable.invalidate(); entries[evictable.identity.recordingID] = nil
        unavailableRecordings.insert(evictable.identity.recordingID)
    }

    func entry(recordingID: UUID) -> Entry? { entries[recordingID] }
    func entry(audioURL: URL) -> Entry? {
        guard let path = try? RecordingDeletionAuthority.canonical(audioURL) else { return nil }
        return entries.values.first {
            $0.artifacts.admittedAudioURL.flatMap { try? RecordingDeletionAuthority.canonical($0) } == path
        }
    }
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

    /// Intent failure leaves the entry valid. A verified receipt retires its
    /// exact producers before cleanup, and remains available across retries.
    func deleteArtifacts(recordingID: UUID) async throws {
        let ticket: DeletionTicket
        if let retained = deletions[recordingID] { ticket = retained }
        else {
            guard deletions.count < 8 else { throw Failure.capacity }
            guard let entry = entries[recordingID] else { throw Failure.unavailable }
            let receipt = try await entry.artifacts.commitDeletionIntent()
            ticket = .init(entry: entry, receipt: receipt)
            deletions[recordingID] = ticket
            entry.invalidate()
            if entries[recordingID] === entry { entries[recordingID] = nil }
            retiredRecordings.insert(recordingID)
        }
        try await ticket.entry.artifacts.writer.cleanupDeletion(ticket.receipt)
    }
    /// The manager releases the ticket only after audio and privacy cleanup.
    func completeDeletion(recordingID: UUID) { deletions[recordingID] = nil }

    private func owned(_ identity: LiveSessionIdentity) throws -> Entry {
        guard !retiredRecordings.contains(identity.recordingID) else { throw Failure.retired }
        guard let entry = entry(identity: identity) else { throw Failure.identityConflict }
        return entry
    }
}
