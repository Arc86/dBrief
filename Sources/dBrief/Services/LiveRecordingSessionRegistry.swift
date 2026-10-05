import Foundation
import dBriefWire

@MainActor
final class LiveRecordingSessionRegistry {
    enum Failure: Error, Equatable { case identityConflict, retired, capacity, unavailable }
    @MainActor final class Entry {
        let identity: LiveSessionIdentity
        let store: LiveTranscriptStore
        let validity: RecordingDerivativeValidity
        let artifacts: LiveRecordingArtifactOwner
        let savedTranscriptOrder = LiveSavedTranscriptOrder()
        let richWriteValidity = RecordingDerivativeValidity()
        private(set) var richDeletionAdmission = RecordingDerivativeValidity()
        func sealRichWritesForDeletion() { richDeletionAdmission.invalidate() }
        func resumeRichWritesAfterFailedIntent() { if isValid { richDeletionAdmission = .init() } }
        private(set) var captureClosed = false
        private(set) var isValid = true
        private(set) var coordinator: LiveCaptureSessionCoordinator?
        fileprivate init(identity: LiveSessionIdentity, native: Bool, root: URL, capturePersistenceAllowed: Bool = true,
                         ramCapture: LiveRAMCaptureMetadata? = nil, reservation: LiveRecordingPayloadBudget.Lease,
                         beforeStage: @escaping @Sendable (LiveArtifactStage) async throws -> Void,
                         afterCheckpoint: @escaping @Sendable () async -> Void,
                         ramFinalClock: @escaping @MainActor () -> Date = { Date.now }) {
            self.identity = identity; validity = RecordingDerivativeValidity()
            self.store = LiveTranscriptStore(identity: identity,validity: validity,
                retainedEvidenceLimit: LiveRecordingArtifactOwner.evidenceLimit, payloadReservation: reservation)
            artifacts = LiveRecordingArtifactOwner(identity: identity, store: store, validity: validity,
                native: native, rootURL: root, payloadReservation: reservation, capturePersistenceAllowed: capturePersistenceAllowed,
                ramCapture: ramCapture, ramFinalClock: ramFinalClock, beforeStage: beforeStage, afterCheckpoint: afterCheckpoint)
        }
        fileprivate init(identity: LiveSessionIdentity, restored: LiveSessionArtifactStore.Restored,
                         writer: LiveSessionArtifactStore, validity: RecordingDerivativeValidity,
                         root: URL, reservation: LiveRecordingPayloadBudget.Lease,
                         beforeStage: @escaping @Sendable (LiveArtifactStage) async throws -> Void) throws {
            self.identity = identity; self.validity = validity
            if let checkpoint = restored.transcript {
                store = try LiveTranscriptStore(restoring: checkpoint, validity: validity, payloadReservation: reservation)
            } else {
                store = LiveTranscriptStore(identity: identity, validity: validity, payloadReservation: reservation)
            }
            artifacts = LiveRecordingArtifactOwner(identity: identity, store: store, validity: validity,
                native: restored.transcript != nil, rootURL: root, payloadReservation: reservation,
                beforeStage: beforeStage, recoveredWriter: writer)
            try artifacts.hydrate(restored); captureClosed = true
        }
        fileprivate func closeCapture() { captureClosed = true; artifacts.closeCapture() }
        fileprivate func configureNonpersistingFinalOnly(audioURL: URL, anchor: (id: UUID, revision: UInt64)?) {
            captureClosed = true; artifacts.configureNonpersistingFinalOnly(audioURL: audioURL, anchor: anchor)
        }
        fileprivate func invalidate() {
            coordinator?.sealAttribution()
            isValid = false; validity.invalidate()
            TranscriptChatService.invalidateOwnedSource(recordingID: identity.recordingID, validity: validity)
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
    private var terminationStarted = false
    private struct DeletionTicket {
        let entry: Entry?
        let writer: LiveSessionArtifactStore
        let receipt: LiveSessionArtifactStore.DeletionReceipt
    }
    private final class Load {
        let identity: LiveSessionIdentity
        let validity = RecordingDerivativeValidity()
        let reservation: LiveRecordingPayloadBudget.Lease
        var task: Task<Entry?, any Error>?
        var waiters = 0
        init(_ identity: LiveSessionIdentity, reservation: LiveRecordingPayloadBudget.Lease) {
            self.identity = identity; self.reservation = reservation
        }
    }
    private final class CatalogueSnapshot: Sendable {
        let values: [UUID: LiveManagedArtifactCatalogue.Hint]
        let reservation: LiveRecordingPayloadBudget.Lease
        init(values: [UUID: LiveManagedArtifactCatalogue.Hint], reservation: LiveRecordingPayloadBudget.Lease) {
            self.values = values; self.reservation = reservation
        }
    }
    private var loads: [UUID: Load] = [:]
    @MainActor final class Replacement {
        let recordingID: UUID
        let authority: RecordingDeletionAuthority
        let isRetention: Bool
        fileprivate var isRecordingRetention = false
        fileprivate var retentionReceipt: LiveSessionArtifactStore.RetentionReceipt?
        fileprivate var retentionWriter: LiveSessionArtifactStore?
        fileprivate var original: Entry?
        fileprivate var pin: LiveRecordingArtifactOwner.Pin?
        fileprivate(set) var identity: LiveSessionIdentity?
        fileprivate(set) var attemptID: UUID?
        fileprivate var retiredOriginal = false
        var retentionCommitted: Bool { isRetention && retiredOriginal }
        fileprivate(set) var discardCompleted = false
        fileprivate var nonpersisting = false
        fileprivate var capturePersistenceAllowed: Bool
        fileprivate let ramCapture: LiveRAMCaptureMetadata?
        fileprivate var ramCandidate: Entry?
        fileprivate var finishTask: Task<Entry?, any Error>?
        fileprivate var finishWaiters = 0
        fileprivate let finalAnchor: (id: UUID, revision: UInt64)?
        fileprivate init(recordingID: UUID, authority: RecordingDeletionAuthority, original: Entry?, isRetention: Bool = false) {
            self.recordingID = recordingID; self.authority = authority; self.original = original; self.isRetention = isRetention
            identity = original?.identity; pin = original?.artifacts.pin()
            nonpersisting = original.map { !$0.artifacts.persistenceStarted } ?? false
            capturePersistenceAllowed = original?.artifacts.capturePersistenceAllowed ?? true
            ramCapture = original?.artifacts.ramMetadata?.capture
            finalAnchor = original?.artifacts.finalAnchor
        }
    }
    private var replacements: [UUID: Replacement] = [:]
    private var exports: [UUID: RecordingDerivativeValidity] = [:]
    private func revokeExport(_ recordingID: UUID) { exports[recordingID]?.invalidate() }
    private var hints: [UUID: LiveManagedArtifactCatalogue.Hint] = [:]
    private var namespaceReservation: LiveRecordingPayloadBudget.Lease?
    private var catalogueTask: Task<CatalogueSnapshot, any Error>?
    private var catalogueID: UUID?
    private var catalogueWaiters = 0
    private var catalogueComplete = false
    private(set) var discoveryFailure: String?
    var onEviction: ((Entry) -> Void)?
    var onHydration: ((Entry) async throws -> Void)?
    var onReplacementRetry: ((Replacement) async throws -> Void)?
    private var deletions: [UUID: DeletionTicket] = [:]
    private var captureOwners: [UUID: UUID] = [:]
    private var retiredRecordings: Set<UUID> = []
    private var unavailableRecordings: Set<UUID> = []
    private let artifactRoot: URL
    private let ownerLimit: Int
    private let beforeStage: @Sendable (LiveArtifactStage) async throws -> Void
    private let afterCheckpoint: @Sendable () async -> Void
    private let ramFinalClock: @MainActor () -> Date
    private let budget: LiveRecordingPayloadBudget
    var reservedPayloadBytes: Int { budget.reservedBytes }
    func reserveAttributionWorking(_ identity: LiveSessionIdentity) throws -> LiveRecordingPayloadBudget.Lease {
        guard !terminationStarted, let entry = entry(identity: identity), entry.isValid, !entry.captureClosed,
              entry.coordinator != nil else { throw Failure.retired }
        return try budget.reserveAuxiliary(bytes: LiveAttributionWorkingSet.limit)
    }
    /// Called synchronously at the original pressure callback, before any hop.
    func sealAttributionForPressure(_ pressure: LiveResourceMeasurement.Pressure) {
        guard pressure != .normal else { return }
        for entry in entries.values { entry.coordinator?.sealAttribution() }
        for replacement in replacements.values { replacement.original?.coordinator?.sealAttribution() }
    }
    func applyResourcePressure(_ measurement: LiveResourceMeasurement, policy: LiveModelResourcePolicy) async {
        let actions = await policy.pressureActions(measurement)
        let owners = Array(entries.values) + replacements.values.compactMap(\.original)
        for owner in owners { owner.coordinator?.retireAttribution(leaseIDs: actions.retireAttribution,policy: policy) }
    }
    func reserveDeletionMaintenance() throws -> LiveRecordingPayloadBudget.Lease { try budget.reserveMaintenance() }
    func reserveInspection() throws -> LiveRecordingPayloadBudget.Lease { try budget.reserveAuxiliary(bytes: LiveManagedArtifactCatalogue.inspectionBytes) }
    func reserveReprocessingInspection() throws -> LiveRecordingPayloadBudget.Lease { try budget.reserveAuxiliary(bytes: 32 * 1_024 * 1_024) }
    var pendingLoads: Int { loads.count }
    var pendingLoadWaiters: Int { loads.values.reduce(0) { $0 + $1.waiters } }
    func hasPendingDeletion(recordingID: UUID) -> Bool { deletions[recordingID] != nil }
    init(artifactRoot: URL = AppSupportPaths.subdirectory("LiveSessions"), ownerLimit: Int = 8,
         beforeStage: @escaping @Sendable (LiveArtifactStage) async throws -> Void = { _ in },
         afterCheckpoint: @escaping @Sendable () async -> Void = {}, payloadBudget: LiveRecordingPayloadBudget? = nil,
         ramFinalClock: @escaping @MainActor () -> Date = { Date.now }) {
        self.artifactRoot = artifactRoot; self.ownerLimit = min(8, max(1, ownerLimit)); self.beforeStage = beforeStage
        self.afterCheckpoint = afterCheckpoint; self.ramFinalClock = ramFinalClock
        budget = payloadBudget ?? LiveRecordingPayloadBudget(ownerLimit: ownerLimit)
    }

    func register(_ identity: LiveSessionIdentity) throws -> Entry {
        try register(identity, native: true)
    }
    func registerLegacy(_ identity: LiveSessionIdentity, capturePersistenceAllowed: Bool = true,
                        ramCapture: LiveRAMCaptureMetadata? = nil) throws -> Entry {
        try register(identity, native: false, capturePersistenceAllowed: capturePersistenceAllowed, ramCapture: ramCapture)
    }
    func startPersistence(_ identity: LiveSessionIdentity) { entry(identity: identity)?.artifacts.start() }
    func owns(recordingID: UUID) -> Bool { captureOwners.values.contains(recordingID) }
    func noteUnavailable(_ identity: LiveSessionIdentity) {
        guard entries[identity.recordingID] == nil, captureOwners[identity.captureSessionID] == nil else { return }
        guard (try? admitNamespace(identity)) != nil else { discoveryFailure = LiveArtifactError.artifactTooLarge.localizedDescription; catalogueComplete = false; return }
        captureOwners[identity.captureSessionID] = identity.recordingID
        unavailableRecordings.insert(identity.recordingID)
    }
    private func register(_ identity: LiveSessionIdentity, native: Bool, capturePersistenceAllowed: Bool = true,
                          ramCapture: LiveRAMCaptureMetadata? = nil) throws -> Entry {
        guard !terminationStarted else { throw LiveArtifactError.terminating }
        guard replacements[identity.recordingID] == nil else { throw Failure.unavailable }
        guard !capturePersistenceAllowed || ramCapture == nil else { throw Failure.identityConflict }
        guard !retiredRecordings.contains(identity.recordingID) else { throw Failure.retired }
        guard !unavailableRecordings.contains(identity.recordingID) else { throw Failure.unavailable }
        if let entry = entries[identity.recordingID] {
            guard entry.identity == identity, entry.artifacts.isNative == native,
                  entry.artifacts.capturePersistenceAllowed == capturePersistenceAllowed,
                  ramCapture == nil || entry.artifacts.ramMetadata?.capture == ramCapture else { throw Failure.identityConflict }
            return entry
        }
        guard captureOwners[identity.captureSessionID] == nil else { throw Failure.identityConflict }
        try admitNamespace(identity)
        guard hints[identity.recordingID] == nil,
              !capturePersistenceAllowed || !FileManager.default.fileExists(atPath: artifactRoot.appendingPathComponent(identity.captureSessionID.uuidString).path) else { throw Failure.unavailable }
        if !budget.canReserve { evictOneDurableOwner() }
        guard entries.count < ownerLimit else { throw Failure.capacity }
        let reservation = try budget.reserve()
        let entry = Entry(identity: identity, native: native, root: artifactRoot, capturePersistenceAllowed: capturePersistenceAllowed,
            ramCapture: ramCapture, reservation: reservation, beforeStage: beforeStage, afterCheckpoint: afterCheckpoint, ramFinalClock: ramFinalClock)
        entries[identity.recordingID] = entry; captureOwners[identity.captureSessionID] = identity.recordingID
        return entry
    }
    private func evictOneDurableOwner() {
        guard let evictable = entries.values.first(where: { replacements[$0.identity.recordingID] == nil && $0.artifacts.canEvict }) else { return }
        let hint = LiveManagedArtifactCatalogue.Hint(identity: evictable.identity, audioURL: evictable.artifacts.admittedAudioURL, deleted: false)
        guard (try? admitHint(hint)) != nil else { return }
        revokeExport(evictable.identity.recordingID)
        onEviction?(evictable)
        evictable.invalidate(); entries[evictable.identity.recordingID] = nil
    }

    func entry(recordingID: UUID) -> Entry? { replacements[recordingID] == nil ? entries[recordingID] : nil }
    func entry(audioURL: URL) -> Entry? {
        guard let path = try? RecordingDeletionAuthority.canonical(audioURL) else { return nil }
        return entries.values.first {
            replacements[$0.identity.recordingID] == nil &&
            $0.artifacts.admittedAudioURL.flatMap { try? RecordingDeletionAuthority.canonical($0) } == path
        }
    }
    func isRetired(recordingID: UUID) -> Bool { retiredRecordings.contains(recordingID) }
    func isKnownDeleted(recordingID: UUID) -> Bool {
        retiredRecordings.contains(recordingID) || hints[recordingID]?.deleted == true || deletions[recordingID] != nil
    }
    func entry(identity: LiveSessionIdentity) -> Entry? {
        guard replacements[identity.recordingID] == nil, let entry = entries[identity.recordingID], entry.identity == identity else { return nil }
        return entry
    }

    /// Resident census includes originals hidden by a replacement phase. No
    /// discovery or cold load is started; pending loads keep their actual work.
    func freezeForTermination() -> (owners: [LiveRecordingArtifactOwner.TerminationTarget], loads: [Task<Entry?, any Error>]) {
        terminationStarted = true
        let pending = loads.values.compactMap(\.task)
        for load in loads.values { load.validity.invalidate() }
        let candidates = replacements.values.compactMap(\.ramCandidate)
        let targets = (Array(entries.values) + candidates).compactMap { $0.artifacts.freezeForTermination() }
        return (targets, pending)
    }

    func captureDidClose(_ identity: LiveSessionIdentity) throws { try owned(identity).closeCapture() }
    func install(_ coordinator: LiveCaptureSessionCoordinator, for identity: LiveSessionIdentity) throws { try owned(identity).install(coordinator) }

    /// Reserve and pin before the first await. This is replacement admission,
    /// never a deletion tombstone, and public resolution cannot bypass it.
    func beginReplacement(recordingID: UUID, audioURL: URL, attemptID: UUID? = nil, isRetention: Bool = false, originalAuthority: RecordingDeletionAuthority? = nil) throws -> Replacement {
        guard !terminationStarted else { throw LiveArtifactError.terminating }
        guard !isKnownDeleted(recordingID: recordingID) else { throw LiveArtifactError.deleted }
        if let phase = replacements[recordingID] {
            guard phase.isRetention == isRetention, (isRetention || attemptID != nil), phase.attemptID == attemptID,
                  try RecordingDeletionAuthority.canonical(audioURL) == phase.authority.audioURL else { throw Failure.unavailable }
            try phase.authority.validateExact(); return phase
        }
        try reserveNamespace()
        guard replacements.count < 8 else { throw Failure.capacity }
        let original = entries[recordingID]
        guard original == nil || original?.captureClosed == true else { throw Failure.unavailable }
        let authority = try originalAuthority ?? RecordingDeletionAuthority(audioURL: audioURL, expectedRecordingID: recordingID)
        try authority.validateExact()
        guard authority.audio.stamp != nil else { throw ReprocessingError.missingAudio }
        let phase = Replacement(recordingID: recordingID, authority: authority, original: original, isRetention: isRetention)
        phase.attemptID = attemptID
        replacements[recordingID] = phase
        revokeExport(recordingID)
        // Cancel an already-started public load. Its reservation still follows
        // its actual task/waiter lifetime and it cannot install across this phase.
        loads[recordingID]?.validity.invalidate()
        do { try original?.artifacts.sealForReplacement() }
        catch { replacements[recordingID] = nil; phase.pin?.release(); throw error }
        return phase
    }

    func resolveForReplacement(_ phase: Replacement) async throws -> Entry? {
        try requireReplacement(phase)
        if phase.retiredOriginal { return nil }
        let entry: Entry?
        if let original = phase.original { entry = original }
        else {
            // Join obsolete public loading before admitting a new private load.
            if let task = loads[phase.recordingID]?.task { _ = try? await task.value }
            entry = try await resolve(recordingID: phase.recordingID, audioURL: phase.authority.audioURL, replacement: phase)
            try requireReplacement(phase)
            phase.original = entry; phase.identity = entry?.identity; phase.pin = entry?.artifacts.pin()
            phase.nonpersisting = entry.map { !$0.artifacts.persistenceStarted } ?? false
            phase.capturePersistenceAllowed = entry?.artifacts.capturePersistenceAllowed ?? true
            try entry?.artifacts.sealForReplacement()
        }
        try requireReplacement(phase)
        return entry
    }

    func adoptReplacement(_ phase: Replacement, attemptID: UUID) throws {
        // The returned journal already owns the result claim. Retire the exact
        // original even if an external replacement changed physical authority
        // while the actor return was pending; no file effects occur here.
        guard replacements[phase.recordingID] === phase,
              phase.attemptID == nil || phase.attemptID == attemptID else { throw Failure.unavailable }
        phase.attemptID = attemptID
        if let original = phase.original {
            RecordingResultMutation.withTransaction {
                onEviction?(original); original.invalidate()
                if entries[phase.recordingID] === original { entries[phase.recordingID] = nil }
            }
        }
        phase.retiredOriginal = true
        phase.original = nil; phase.pin?.release(); phase.pin = nil
        try requireReplacement(phase)
    }

    func abandonReplacement(_ phase: Replacement) {
        guard replacements[phase.recordingID] === phase, !phase.retiredOriginal, phase.attemptID == nil else { return }
        phase.original?.artifacts.reopenAfterFailedReplacement()
        phase.pin?.release(); phase.pin = nil; replacements[phase.recordingID] = nil
    }

    func finishReplacement(_ phase: Replacement,
                           prepare: @escaping @MainActor () async throws -> Void = {}) async throws -> Entry? {
        try requireReplacement(phase)
        guard phase.finishWaiters < 8 else { throw Failure.capacity }
        let task: Task<Entry?, any Error>
        if let existing = phase.finishTask { task = existing }
        else {
            task = Task {
                defer { phase.finishTask = nil }
                try await prepare()
                return try await self.installReplacement(phase)
            }
            phase.finishTask = task
        }
        phase.finishWaiters += 1; defer { phase.finishWaiters -= 1 }
        let entry = try await task.value
        try Task.checkCancellation()
        guard entry == nil || entry?.isValid == true else { throw Failure.retired }
        return entry
    }

    private func installReplacement(_ phase: Replacement) async throws -> Entry? {
        guard !terminationStarted else { throw LiveArtifactError.terminating }
        try requireReplacement(phase)
        if phase.nonpersisting, let identity = phase.identity {
            guard entries[phase.recordingID] == nil else { throw Failure.identityConflict }
            if !budget.canReserve { evictOneDurableOwner() }
            guard phase.ramCandidate == nil else { throw Failure.unavailable }
            let entry = Entry(identity: identity, native: false, root: artifactRoot, capturePersistenceAllowed: phase.capturePersistenceAllowed,
                ramCapture: phase.ramCapture, reservation: try budget.reserve(), beforeStage: beforeStage, afterCheckpoint: afterCheckpoint,
                ramFinalClock: ramFinalClock)
            entry.configureNonpersistingFinalOnly(audioURL: phase.authority.audioURL, anchor: phase.finalAnchor)
            var installed = false
            if !phase.capturePersistenceAllowed { phase.ramCandidate = entry }
            defer {
                if !phase.capturePersistenceAllowed {
                    if !installed { entry.invalidate() }
                    if phase.ramCandidate === entry { phase.ramCandidate = nil }
                }
            }
            try await onHydration?(entry)
            guard !terminationStarted else { throw LiveArtifactError.terminating }
            try requireReplacement(phase)
            entries[phase.recordingID] = entry; replacements[phase.recordingID] = nil
            installed = true
            return entry
        }
        // Private resolution and the hydration callback run before admission
        // reopens. Cancellation/failed hydration keeps the phase visibly pending.
        let entry = try await resolve(recordingID: phase.recordingID, audioURL: phase.authority.audioURL, replacement: phase)
        try requireReplacement(phase)
        replacements[phase.recordingID] = nil
        return entry
    }

    func beginRetention(recordingID: UUID, authority: RecordingDeletionAuthority, recordingExpiry: Bool = false) throws -> Replacement? {
        if let phase = replacements[recordingID] {
            guard phase.isRetention, phase.isRecordingRetention == recordingExpiry else { throw Failure.unavailable }; try phase.authority.validateExact(); return phase
        }
        if let owner = entries[recordingID], !owner.artifacts.canExpire { return nil }
        let phase = try beginReplacement(recordingID: recordingID, audioURL: authority.audioURL,
            isRetention: true, originalAuthority: authority)
        phase.isRecordingRetention = recordingExpiry
        return phase
    }
    func adoptRetention(_ phase: Replacement, receipt: LiveSessionArtifactStore.RetentionReceipt,
                        writer: LiveSessionArtifactStore) throws {
        guard replacements[phase.recordingID] === phase, phase.isRetention,
              receipt.identity == phase.identity else { throw Failure.identityConflict }
        // Adopt durable authority before reporting cancellation or replacement.
        phase.retentionReceipt = receipt; phase.retentionWriter = writer
        if let original = phase.original {
            RecordingResultMutation.withTransaction {
                onEviction?(original); original.invalidate()
                if entries[phase.recordingID] === original { entries[phase.recordingID] = nil }
            }
        }
        phase.retiredOriginal = true; phase.original = nil; phase.pin?.release(); phase.pin = nil
        try requireReplacement(phase)
    }
    func finishRetention(_ phase: Replacement) async throws {
        guard replacements[phase.recordingID] === phase, phase.isRetention, !phase.isRecordingRetention,
              let receipt = phase.retentionReceipt, let writer = phase.retentionWriter else { throw Failure.unavailable }
        try await writer.cleanupRetention(receipt)
        try requireReplacement(phase)
        if let identity = phase.identity { try admitHint(.init(identity: identity, audioURL: phase.authority.audioURL, deleted: false)) }
        replacements[phase.recordingID] = nil
    }
    func isExplicitReprocessingReplacement(recordingID: UUID) -> Bool { replacements[recordingID]?.isRetention == false }
    var retentionHints: [LiveManagedArtifactCatalogue.Hint] {
        var values = hints
        for entry in entries.values {
            values[entry.identity.recordingID] = .init(identity: entry.identity, audioURL: entry.artifacts.admittedAudioURL,
                deleted: false, ram: entry.artifacts.ramMetadata)
        }
        return Array(values.values)
    }

    func prepareHistoryExport(recordingID: UUID, audioURL: URL?) async throws -> LiveHistoryExportSnapshot {
        guard exports[recordingID] == nil, exports.count < 8, replacements[recordingID] == nil,
              !isKnownDeleted(recordingID: recordingID) else { throw Failure.unavailable }
        guard entries[recordingID]?.artifacts.capturePersistenceAllowed != false else { throw LiveArtifactError.missingEvidence }
        let token = RecordingDerivativeValidity(), original = entries[recordingID]
        let pin = original?.artifacts.pin()
        let reservation = try reserveReprocessingInspection()
        let authority = try audioURL.map { try RecordingDeletionAuthority(audioURL: $0, expectedRecordingID: recordingID) }
        exports[recordingID] = token
        defer { if exports[recordingID] === token { exports[recordingID] = nil }; pin?.release() }
        try await discover()
        try token.withValidResult {}
        guard replacements[recordingID] == nil, !isKnownDeleted(recordingID: recordingID),
              let identity = original?.identity ?? hints[recordingID]?.identity else { throw Failure.unavailable }
        if let requested = authority?.audioURL, let bound = original?.artifacts.admittedAudioURL ?? hints[recordingID]?.audioURL {
            guard try RecordingDeletionAuthority.canonical(bound) == requested else { throw LiveArtifactError.wrongOwner }
        }
        let writer = original?.artifacts.writer ?? LiveSessionArtifactStore(identity: identity, rootURL: artifactRoot, validity: token,
            payloadReservation: reservation, payloadLimit: 3 * 1_024 * 1_024, queueByteLimit: 3 * 1_024 * 1_024,
            chatPayloadLimit: LiveRecordingArtifactOwner.chatHistoryLimit, beforeStage: beforeStage)
        let snapshot = try await writer.inspectForExport()
        try Task.checkCancellation(); try token.withValidResult {}
        guard original == nil || original?.isValid == true else { throw Failure.retired }
        guard !snapshot.deleted, snapshot.transcriptValue != nil || snapshot.chat != nil else { throw LiveArtifactError.missingEvidence }
        let value = LiveHistoryExport(identity: identity, native: snapshot.appTranscript == nil ? snapshot.transcript : nil, app: snapshot.appTranscript, chat: snapshot.chat)
        let data = try LiveArtifactEncoding.encode(value, limit: 4 * 1_024 * 1_024)
        try RecordingResultMutation.withTransaction {
            try token.withValidResult {}; try authority?.validateExact()
            // Payloads may advance normally after the snapshot. Routing, deletion
            // and master ownership cannot change while its result is prepared.
            for item in snapshot.authority where !["chat.json", "live-transcript.json"].contains(where: { item.url.lastPathComponent.hasSuffix($0) }) {
                try LiveSessionArtifactStore.requireSafeParents(item.url)
                guard try RecordingDeletionAuthority.Stamp.read(item.url) == item.stamp else { throw LiveArtifactError.wrongOwner }
            }
        }
        return .init(data: data, identity: identity, reservation: reservation)
    }

    func replacement(attemptID: UUID) -> Replacement? { replacements.values.first { $0.attemptID == attemptID } }
    func permitsProcessing(recordingID: UUID, attemptID: UUID?) -> Bool {
        guard let phase = replacements[recordingID] else { return true }
        return attemptID != nil && phase.attemptID == attemptID
    }
    var pendingReplacements: [Replacement] { Array(replacements.values) }
    func noteCompletedDiscard(_ phase: Replacement, attemptID: UUID) throws {
        guard replacements[phase.recordingID] === phase, phase.attemptID == attemptID, phase.retiredOriginal else { throw Failure.unavailable }
        phase.discardCompleted = true
    }

    private func requireReplacement(_ phase: Replacement) throws {
        guard replacements[phase.recordingID] === phase else { throw Failure.unavailable }
        guard !isKnownDeleted(recordingID: phase.recordingID) else { throw LiveArtifactError.deleted }
        try phase.authority.validateExact()
    }

    /// Retire the owner synchronously before asynchronous artifact cleanup. This
    /// removes lookup and tombstones identities without destroying other history.
    func retire(_ identity: LiveSessionIdentity) throws {
        revokeExport(identity.recordingID)
        if let load = loads[identity.recordingID], load.identity == identity {
            load.validity.invalidate(); retiredRecordings.insert(identity.recordingID); return
        }
        let entry = try owned(identity)
        entry.invalidate(); entries[identity.recordingID] = nil
        retiredRecordings.insert(identity.recordingID)
        // Retain the capture namespace tombstone; a late attach cannot alias it.
    }

    /// Intent failure leaves the entry valid. A verified receipt retires its
    /// exact producers before cleanup, and remains available across retries.
    func deleteArtifacts(recordingID: UUID, retention: ProcessingPipeline.FileDeletionTicket? = nil) async throws {
        revokeExport(recordingID)
        let ticket: DeletionTicket
        if let retained = deletions[recordingID] { ticket = retained }
        else {
            guard deletions.count < 8 else { throw Failure.capacity }
            guard let entry = entries[recordingID] else { throw Failure.unavailable }
            let receipt = try await entry.artifacts.commitDeletionIntent(retention: retention)
            ticket = .init(entry: entry, writer: entry.artifacts.writer, receipt: receipt)
            deletions[recordingID] = ticket
            entry.invalidate()
            if entries[recordingID] === entry { entries[recordingID] = nil }
            retiredRecordings.insert(recordingID)
            if let phase = replacements[recordingID], phase.isRecordingRetention, phase.original === entry {
                // Receipt adoption retires and releases the exact admission
                // barrier before cleanup can suspend or report an error.
                phase.retiredOriginal = true; phase.original = nil; phase.pin?.release(); phase.pin = nil
                replacements[recordingID] = nil
            }
        }
        try await ticket.writer.cleanupDeletion(ticket.receipt)
    }
    func recordingRetentionTicket(recordingID: UUID) async throws -> ProcessingPipeline.FileDeletionTicket? {
        guard let hint = hints[recordingID], hint.deleted else { return nil }
        let reservation = try reserveDeletionMaintenance()
        let writer = LiveSessionArtifactStore(identity: hint.identity, rootURL: artifactRoot,
            payloadReservation: reservation, payloadLimit: RecordingDeletionAuthority.ticketLimit, beforeStage: beforeStage)
        return try await writer.inspectRecordingRetention()
    }
    /// The manager releases the ticket only after audio and privacy cleanup.
    func completeDeletion(recordingID: UUID) { deletions[recordingID] = nil }

    private func owned(_ identity: LiveSessionIdentity) throws -> Entry {
        guard !retiredRecordings.contains(identity.recordingID) else { throw Failure.retired }
        guard let entry = entry(identity: identity) else { throw Failure.identityConflict }
        return entry
    }

    private func admitNamespace(_ identity: LiveSessionIdentity) throws {
        try reserveNamespace()
        guard captureOwners[identity.captureSessionID] == nil || captureOwners[identity.captureSessionID] == identity.recordingID else { throw Failure.identityConflict }
        guard captureOwners[identity.captureSessionID] != nil || captureOwners.count < LiveManagedArtifactCatalogue.hintLimit else { throw Failure.capacity }
    }
    private func reserveNamespace() throws {
        if namespaceReservation == nil { namespaceReservation = try budget.reserveAuxiliary(bytes: LiveManagedArtifactCatalogue.metadataBytes) }
    }
    private func admitHint(_ hint: LiveManagedArtifactCatalogue.Hint) throws {
        try admitNamespace(hint.identity)
        guard hints[hint.identity.recordingID] == nil || hints[hint.identity.recordingID]?.identity == hint.identity else { throw Failure.identityConflict }
        let bytes = hints.values.reduce(0) { $0 + $1.charge } - (hints[hint.identity.recordingID]?.charge ?? 0) + hint.charge
        guard hints.count < LiveManagedArtifactCatalogue.hintLimit || hints[hint.identity.recordingID] != nil,
              bytes <= LiveManagedArtifactCatalogue.hintByteLimit else { throw Failure.capacity }
        try validateHintAudio(hint, among: hints.values)
        hints[hint.identity.recordingID] = hint
        captureOwners[hint.identity.captureSessionID] = hint.identity.recordingID
    }

    /// One scan, bounded waiters and a reservation before raw header reads.
    /// The scan's reservation is released before a full owner is admitted.
    func discover(refresh: Bool = false) async throws {
        if catalogueComplete, !refresh { return }
        guard catalogueWaiters < 8 else { throw Failure.capacity }
        try reserveNamespace()
        catalogueWaiters += 1; defer { catalogueWaiters -= 1 }
        let task: Task<CatalogueSnapshot, any Error>
        let scanID: UUID
        if let existing = catalogueTask, let id = catalogueID { task = existing; scanID = id }
        else {
            let resultReservation = try budget.reserveAuxiliary(bytes: LiveManagedArtifactCatalogue.hintByteLimit)
            let inspection = try budget.reserveAuxiliary(bytes: LiveManagedArtifactCatalogue.inspectionBytes)
            catalogueComplete = false
            let root = artifactRoot, stage = beforeStage
            task = Task.detached {
                defer { withExtendedLifetime(inspection) {} }
                try await stage(.catalogueRead)
                return try CatalogueSnapshot(values: LiveManagedArtifactCatalogue.inspect(root: root), reservation: resultReservation)
            }
            scanID = UUID(); catalogueTask = task; catalogueID = scanID
        }
        do {
            let snapshot = try await task.value
            defer { withExtendedLifetime(snapshot) {} }
            let values = snapshot.values
            try await beforeStage(.cataloguePublication)
            if catalogueID == scanID {
                // Validate the whole proposal before installing any hint. A
                // capture admitted during inspection remains authoritative.
                let newCaptures = values.values.reduce(0) { $0 + (captureOwners[$1.identity.captureSessionID] == nil ? 1 : 0) }
                guard captureOwners.count + newCaptures <= LiveManagedArtifactCatalogue.hintLimit else { throw Failure.capacity }
                for hint in values.values {
                    guard captureOwners[hint.identity.captureSessionID] == nil || captureOwners[hint.identity.captureSessionID] == hint.identity.recordingID,
                          entries[hint.identity.recordingID] == nil || entries[hint.identity.recordingID]?.identity == hint.identity,
                          hints[hint.identity.recordingID] == nil || hints[hint.identity.recordingID]?.identity == hint.identity,
                          entries[hint.identity.recordingID]?.artifacts.capturePersistenceAllowed != false,
                          replacements[hint.identity.recordingID]?.capturePersistenceAllowed != false else { throw Failure.identityConflict }
                }
                let newIDs = values.keys.reduce(0) { $0 + (hints[$1] == nil ? 1 : 0) }
                func effective(_ proposed: LiveManagedArtifactCatalogue.Hint) -> LiveManagedArtifactCatalogue.Hint {
                    if let prior = hints[proposed.identity.recordingID], prior.deleted { return prior }
                    return proposed
                }
                let bytes = hints.values.reduce(0) { $0 + $1.charge } + values.values.reduce(0) {
                    $0 + effective($1).charge - (hints[$1.identity.recordingID]?.charge ?? 0)
                }
                guard hints.count + newIDs <= LiveManagedArtifactCatalogue.hintLimit,
                      bytes <= LiveManagedArtifactCatalogue.hintByteLimit else { throw Failure.capacity }
                // No third hint map: one temporary alias index fits the fixed
                // 64KiB remainder in the 1MiB metadata reservation.
                var audioOwners: [URL: UUID] = [:]
                func checkAudio(_ hint: LiveManagedArtifactCatalogue.Hint) throws {
                    guard let audio = hint.audioURL else { return }
                    let path = try RecordingDeletionAuthority.canonical(audio)
                    guard audioOwners[path] == nil || audioOwners[path] == hint.identity.recordingID else { throw Failure.identityConflict }
                    audioOwners[path] = hint.identity.recordingID
                }
                for hint in values.values { try checkAudio(effective(hint)) }
                for hint in hints.values where values[hint.identity.recordingID] == nil { try checkAudio(hint) }
                for (id, hint) in values { hints[id] = effective(hint) }
                for hint in values.values { captureOwners[hint.identity.captureSessionID] = hint.identity.recordingID }
                for hint in hints.values where hint.deleted {
                    if let entry = entries[hint.identity.recordingID], entry.identity == hint.identity {
                        revokeExport(entry.identity.recordingID)
                        onEviction?(entry)
                        entry.invalidate(); entries[hint.identity.recordingID] = nil
                    }
                }
                // Hints revoke provider admission, but only full recovery may
                // verify a receipt and grant cleanup authority.
                catalogueComplete = true; discoveryFailure = nil
            } else { guard catalogueComplete, catalogueTask == nil else { throw Failure.unavailable } }
            if catalogueID == scanID { catalogueTask = nil; catalogueID = nil }
        } catch {
            if catalogueID == scanID {
                catalogueTask = nil; catalogueID = nil; catalogueComplete = false
                discoveryFailure = "Saved live history could not be inspected. Retry after checking storage."
            }
            throw error
        }
        try Task.checkCancellation()
    }

    func knownRecordingID(audioURL: URL) -> UUID? {
        guard let path = try? RecordingDeletionAuthority.canonical(audioURL) else { return nil }
        return entry(audioURL: audioURL)?.identity.recordingID ?? hints.values.first {
            $0.audioURL.flatMap { try? RecordingDeletionAuthority.canonical($0) } == path
        }?.identity.recordingID
    }

    /// Nil means confirmed legacy only after complete safe discovery. Owned
    /// but missing/corrupt/deleted evidence never selects the legacy provider.
    func resolve(recordingID: UUID, audioURL: URL? = nil, forDeletion: Bool = false) async throws -> Entry? {
        guard !terminationStarted else { throw LiveArtifactError.terminating }
        if let phase = replacements[recordingID], !forDeletion {
            if let audioURL, try RecordingDeletionAuthority.canonical(audioURL) != phase.authority.audioURL { throw LiveArtifactError.wrongOwner }
            if phase.isRetention { try await finishRetention(phase) }
            else { try await onReplacementRetry?(phase) }
        }
        return try await resolve(recordingID: recordingID, audioURL: audioURL, forDeletion: forDeletion, replacement: nil)
    }
    private func resolve(recordingID: UUID, audioURL: URL? = nil, forDeletion: Bool = false, replacement: Replacement?) async throws -> Entry? {
        func requireAdmission() throws {
            guard !terminationStarted else { throw LiveArtifactError.terminating }
            guard replacements[recordingID] == nil || replacements[recordingID] === replacement else { throw Failure.unavailable }
        }
        try requireAdmission()
        if hints[recordingID]?.deleted == true, !forDeletion { throw LiveArtifactError.deleted }
        if let entry = entries[recordingID], entry.isValid { try validateAudioAssociation(entry, audioURL); return entry }
        if forDeletion, deletions[recordingID] != nil { return nil }
        guard !retiredRecordings.contains(recordingID) else { throw Failure.retired }
        try await discover(refresh: catalogueComplete && hints[recordingID] == nil && loads[recordingID] == nil)
        try await beforeStage(.registryResolution)
        try Task.checkCancellation()
        try requireAdmission()
        if hints[recordingID]?.deleted == true, !forDeletion { throw LiveArtifactError.deleted }
        if let entry = entries[recordingID], entry.isValid { try validateAudioAssociation(entry, audioURL); return entry }
        if forDeletion, deletions[recordingID] != nil { return nil }
        guard !retiredRecordings.contains(recordingID) else { throw Failure.retired }
        guard !unavailableRecordings.contains(recordingID) else { throw Failure.unavailable }
        guard let hint = hints[recordingID] else {
            guard !owns(recordingID: recordingID) else { throw Failure.unavailable }
            if let audioURL {
                let inspection = try reserveInspection()
                try await Task.detached {
                    defer { withExtendedLifetime(inspection) {} }
                    for suffix in ["live-binding.json", "live-transcript.json"] {
                        guard try RecordingDeletionAuthority.Stamp.read(audioURL.deletingPathExtension().appendingPathExtension(suffix)) == nil else { throw Failure.unavailable }
                    }
                    struct ChatOwner: Decodable {
                        let version: Int
                        let identity: LiveSessionIdentity?
                        let revision: UInt64?
                        let bindingGeneration: UUID?
                    }
                    let url = audioURL.deletingPathExtension().appendingPathExtension("chat.json")
                    try LiveSessionArtifactStore.requireSafeParents(url)
                    let owner: ChatOwner? = try RecordingDeletionAuthority.readHeader(url, maximumBytes: 3 * 1_024 * 1_024, tokenLimit: 1_048_576)
                    guard owner == nil || (1...ChatHistory.currentVersion).contains(owner!.version) else { throw LiveArtifactError.unsupportedVersion }
                    guard owner?.identity == nil, owner?.revision == nil, owner?.bindingGeneration == nil else { throw Failure.unavailable }
                }.value
                try Task.checkCancellation()
                try requireAdmission()
                if let entry = entries[recordingID], entry.isValid { try validateAudioAssociation(entry, audioURL); return entry }
                guard !owns(recordingID: recordingID), !retiredRecordings.contains(recordingID) else { throw Failure.unavailable }
            }
            return nil
        }
        if hint.deleted, !forDeletion { throw LiveArtifactError.deleted }
        let phase: Load
        if let existing = loads[recordingID] { phase = existing }
        else {
            guard loads.count < 8 else { throw Failure.capacity }
            if !budget.canReserve || entries.count >= ownerLimit { evictOneDurableOwner() }
            guard entries.count + loads.count < ownerLimit else { throw Failure.capacity }
            phase = Load(hint.identity, reservation: try budget.reserve())
            loads[recordingID] = phase
            let writer = LiveSessionArtifactStore(identity: hint.identity, rootURL: artifactRoot, validity: phase.validity,
                payloadReservation: phase.reservation, payloadLimit: 3 * 1_024 * 1_024, queueByteLimit: 3 * 1_024 * 1_024,
                chatPayloadLimit: LiveRecordingArtifactOwner.chatHistoryLimit, beforeStage: beforeStage)
            phase.task = Task { [self, phase] in
                defer { if loads[recordingID] === phase { loads[recordingID] = nil }; phase.task = nil }
                let restored: LiveSessionArtifactStore.Restored
                if let attemptID = replacement?.attemptID, replacement?.retiredOriginal == false {
                    restored = try await writer.inspectForReprocessing(attemptID: attemptID)
                } else { restored = try await writer.recover(cleanupDeletedArtifacts: false) }
                try await beforeStage(.ownerHydration)
                try phase.validity.withValidResult {}
                try requireAdmission()
                guard !retiredRecordings.contains(recordingID), entries[recordingID] == nil else { throw Failure.retired }
                if restored.deleted {
                    guard deletions.count < 8 else { throw Failure.capacity }
                    let receipt = try await writer.commitDeletionIntent()
                    deletions[recordingID] = .init(entry: nil, writer: writer, receipt: receipt)
                    phase.validity.invalidate(); retiredRecordings.insert(recordingID)
                    return nil
                }
                guard !hint.deleted, hints[recordingID]?.deleted != true else { throw LiveArtifactError.deleted }
                guard restored.transcriptValue != nil || restored.chat != nil else { throw LiveArtifactError.missingEvidence }
                let entry = try RecordingResultMutation.withTransaction {
                    try phase.validity.withValidResult {
                        try restored.validateAuthority()
                        let entry = try Entry(identity: phase.identity, restored: restored, writer: writer, validity: phase.validity,
                            root: artifactRoot, reservation: phase.reservation, beforeStage: beforeStage)
                        return entry
                    }
                }
                if !forDeletion, replacement == nil || replacement?.retiredOriginal == true { try await onHydration?(entry) }
                try requireAdmission()
                try phase.validity.withValidResult {}
                guard !isKnownDeleted(recordingID: recordingID), entries[recordingID] == nil else { throw Failure.retired }
                // The callback can advance our own ledger. Recover its new
                // authority rather than validating obsolete pre-write stamps.
                let current: LiveSessionArtifactStore.Restored
                if let attemptID = replacement?.attemptID, replacement?.retiredOriginal == false {
                    current = try await writer.inspectForReprocessing(attemptID: attemptID)
                } else { current = try await writer.recover(cleanupDeletedArtifacts: false) }
                return try RecordingResultMutation.withTransaction {
                    try phase.validity.withValidResult {
                        try requireAdmission()
                        guard !current.deleted, !isKnownDeleted(recordingID: recordingID) else { throw LiveArtifactError.deleted }
                        try current.validateAuthority()
                        entries[recordingID] = entry
                        return entry
                    }
                }
            }
        }
        guard phase.waiters < 8, let task = phase.task else { throw Failure.capacity }
        phase.waiters += 1; defer { phase.waiters -= 1 }
        let entry = try await task.value
        try Task.checkCancellation()
        try requireAdmission()
        if entry == nil, !forDeletion { throw LiveArtifactError.deleted }
        guard entry == nil || entry?.isValid == true else { throw Failure.retired }
        if let entry { try validateAudioAssociation(entry, audioURL) }
        return entry
    }
    private func validateAudioAssociation(_ entry: Entry, _ requested: URL?) throws {
        if let requested, let admitted = entry.artifacts.admittedAudioURL {
            guard try RecordingDeletionAuthority.canonical(requested) == RecordingDeletionAuthority.canonical(admitted) else { throw LiveArtifactError.wrongOwner }
        }
    }
    private func validateHintAudio(_ hint: LiveManagedArtifactCatalogue.Hint, among values: Dictionary<UUID, LiveManagedArtifactCatalogue.Hint>.Values) throws {
        guard let audio = hint.audioURL else { return }
        let path = try RecordingDeletionAuthority.canonical(audio)
        for other in values where other.identity.recordingID != hint.identity.recordingID {
            if let candidate = other.audioURL, try RecordingDeletionAuthority.canonical(candidate) == path { throw Failure.identityConflict }
        }
    }
}
