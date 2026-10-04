import Foundation
import dBriefWire

extension RecordingManager {
    /// This scope owns inspection through actual writer/store return. It does
    /// not retain a second full historical result while native work is running.
    func prepareManagedReprocessing(_ phase: LiveRecordingSessionRegistry.Replacement,
                                    request: inout ReprocessingRequest, attempt: ReprocessingStore.Attempt? = nil,
                                    inspectionReservation: LiveRecordingPayloadBudget.Lease? = nil) async throws {
        let registry = appState.liveRecordingSessions
        try Task.checkCancellation()
        try attempt?.authority?.validateExact()
        let inspection = try inspectionReservation ?? registry.reserveReprocessingInspection()
        defer { withExtendedLifetime(inspection) {} }
        let entry = try await registry.resolveForReplacement(phase)
        if let entry {
            guard entry.identity.recordingID == request.recordingID else { throw LiveArtifactError.wrongOwner }
            transcriptChatStore?.remove(for: entry.identity.recordingID, owner: entry.artifacts)
            if entry.artifacts.persistenceStarted {
                if !entry.artifacts.isDurable { try await entry.artifacts.flush() }
                let restored: LiveSessionArtifactStore.Restored
                if let attempt { restored = try await entry.artifacts.writer.inspectForReprocessing(attemptID: attempt.id) }
                else { restored = try await entry.artifacts.writer.recover(cleanupDeletedArtifacts: false) }
                try restored.validateAuthority()
                guard !restored.deleted, let audio = restored.audioURL,
                      try RecordingDeletionAuthority.canonical(audio) == phase.authority.audioURL,
                      (restored.transcriptValue?.identity ?? restored.chat?.identity) == entry.identity else {
                    throw LiveArtifactError.wrongOwner
                }
            }
            guard request.liveSessionIdentity == nil || request.liveSessionIdentity == entry.identity else { throw LiveArtifactError.wrongOwner }
            request.liveSessionIdentity = entry.identity
            request.liveHistoryPersisted = entry.artifacts.persistenceStarted
        } else if let identity = phase.identity {
            guard request.liveSessionIdentity == identity else { throw LiveArtifactError.wrongOwner }
        } else if request.liveSessionIdentity != nil {
            throw LiveArtifactError.missingEvidence
        }
        try phase.authority.validateExact()
        try Task.checkCancellation()
        guard !registry.isKnownDeleted(recordingID: request.recordingID) else { throw LiveArtifactError.deleted }
        if let attempt, let identity = request.liveSessionIdentity {
            let configuration = try LiveArtifactEncoding.encode(request, limit: 512 * 1_024)
            try await reprocessingStore.qualifyManaged(attemptID: attempt.id, expectedConfiguration: attempt.configuration,
                configuration: configuration, identity: identity, authority: phase.authority)
            try phase.authority.validateExact()
        }
    }

    func prepareManagedAttempt(_ phase: LiveRecordingSessionRegistry.Replacement,
                               request: ReprocessingRequest) async throws -> ReprocessingStore.Attempt {
        let inspection = try appState.liveRecordingSessions.reserveReprocessingInspection()
        defer { withExtendedLifetime(inspection) {} }
        try Task.checkCancellation()
        let attempt = try await reprocessingStore.prepare(audioURL: phase.authority.audioURL,
            configuration: LiveArtifactEncoding.encode(request, limit: 512 * 1_024), authority: phase.authority)
        try appState.liveRecordingSessions.adoptReplacement(phase, attemptID: attempt.id)
        return attempt
    }

    func prepareManagedRestoration(_ phase: LiveRecordingSessionRegistry.Replacement) async throws -> ReprocessingStore.Attempt {
        let inspection = try appState.liveRecordingSessions.reserveReprocessingInspection()
        defer { withExtendedLifetime(inspection) {} }
        guard let prior = try await reprocessingStore.latestCompleted(audioURL: phase.authority.audioURL) else { throw ReprocessingStore.StoreError.noPreviousResults }
        var request = try JSONDecoder().decode(ReprocessingRequest.self, from: prior.configuration)
        try await prepareManagedReprocessing(phase, request: &request, inspectionReservation: inspection)
        let restoration = try await reprocessingStore.prepareRestoration(audioURL: phase.authority.audioURL,
            managedIdentity: request.liveHistoryPersisted == false ? nil : request.liveSessionIdentity,
            configuration: LiveArtifactEncoding.encode(request, limit: 512 * 1_024), preserveChat: request.liveSessionIdentity != nil, authority: phase.authority)
        try appState.liveRecordingSessions.adoptReplacement(phase, attemptID: restoration.id)
        return restoration
    }

    func reconcileManagedReprocessing(_ entry: LiveRecordingSessionRegistry.Entry) async throws {
        guard let audio = entry.artifacts.admittedAudioURL else { return }
        let inspection = try appState.liveRecordingSessions.reserveReprocessingInspection()
        defer { withExtendedLifetime(inspection) {} }
        if let result = try await reprocessingStore.managedFinal(audioURL: audio, identity: entry.identity,
            nonpersistingReplacement: entry.artifacts.isNonpersistingFinalOnly) {
            try await entry.artifacts.reconcileFinal(result)
        }
    }

    func finishManagedReprocessing(_ attemptID: UUID) async throws {
        if let phase = appState.liveRecordingSessions.replacement(attemptID: attemptID) {
            _ = try await appState.liveRecordingSessions.finishReplacement(phase)
        }
    }

    private func replacementIsComplete(_ phase: LiveRecordingSessionRegistry.Replacement) async throws -> Bool {
        if phase.discardCompleted { return true }
        guard let id = phase.attemptID else { return false }
        let inspection = try appState.liveRecordingSessions.reserveReprocessingInspection()
        defer { withExtendedLifetime(inspection) {} }
        let attempt = try await reprocessingStore.load(attemptID: id)
        guard try RecordingDeletionAuthority.canonical(attempt.audioURL) == phase.authority.audioURL else { throw LiveArtifactError.wrongOwner }
        return attempt.status == .completed
    }

    func retryManagedReprocessing(_ phase: LiveRecordingSessionRegistry.Replacement) async throws {
        // Release the manifest inspection before allocating a fresh owner and
        // its separate reconciliation inspection. Unfinished claims stay closed.
        _ = try await appState.liveRecordingSessions.finishReplacement(phase, prepare: { [weak self] in
            guard let self, try await self.replacementIsComplete(phase) else { throw ReprocessingError.pendingAttempt }
        })
    }
}
