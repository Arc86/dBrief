import Foundation
import os

extension ProcessingPipeline {
    struct DiscardRequest: Codable, Sendable {
        let recordingID: UUID
        let recoveryManifestURL: URL?
        let audioURL: URL
        let finalized: Bool
        let knownFiles: [URL]
        let pendingReceiptURL: URL?
    }
    struct DeletionFiles: Sendable {
        var fileManager: @Sendable () -> FileManager = { .default }
        var record: @Sendable (DurabilityEvent) -> Void = { DurabilityJournal.shared.record($0) }
        var beforeRemoval: @Sendable () async throws -> Void = {}
        var removeEvidence: @Sendable (PrivacyReceiptStore, FileDeletionTicket) async throws -> Void = { store, ticket in
            try await store.removeEvidence(afterDeletion: ticket)
        }
    }

    /// Capture/post-recording ownership remains with the manager across this
    /// await. Once deletion is requested, best-effort cleanup finishes even if
    /// its caller is cancelled; evidence is removed only with proof of deletion.
    func discardRecordingFiles(_ input: DiscardRequest, store: PrivacyReceiptStore,
                               files: DeletionFiles = .init()) async {
        let fm = files.fileManager()
        // Collect ownership before deleting either recovery or metadata files.
        var targets = await store.deletionTargets(for: input.audioURL, recordingIDs: [input.recordingID])
        if let pending = input.pendingReceiptURL { targets.append(pending) }
        var removedSessionDirectory: URL?
        if let manifest = input.recoveryManifestURL {
            do {
                try InterruptedSessionStore.removeSession(containing: manifest, finalState: .discarded, fileManager: fm)
                removedSessionDirectory = manifest.deletingLastPathComponent()
            } catch {
                files.record(.init(sessionID: input.recordingID, name: "recovery_session_discarded",
                                   outcome: .warning, failure: .init(error: error)))
            }
        }
        files.record(.init(sessionID: input.recordingID, name: "recording_discarded_by_user", outcome: .succeeded))
        for url in Set(input.knownFiles) { try? fm.removeItem(at: url) }
        guard input.knownFiles.allSatisfy({ !fm.fileExists(atPath: $0.path) }),
              PrivacyReceiptLifecycle.canRemoveDiscardedEvidence(audioURL: input.audioURL,
                finalized: input.finalized, knownFiles: input.knownFiles,
                removedSessionDirectory: removedSessionDirectory, fileManager: fm) else { return }
        do { try await store.removeEvidence(at: targets) }
        catch { Logger.recording.error("Discard could not remove all privacy evidence") }
    }

    /// Caller holds maintenance admission until this workflow and its UI refresh
    /// finish. Snapshot corruption blocks deletion; individual file failures do
    /// not stop other cleanup, but the first failure is returned to the caller.
    func deleteRecordingFiles(_ audioURL: URL, lifecycle: RecoveryLifecycle,
                              store: PrivacyReceiptStore = .shared, files: DeletionFiles = .init()) async throws {
        let fm = files.fileManager()
        let owners = try await lifecycle.privacyOwners()
        let path = audioURL.resolvingSymlinksInPath()
        let ids = owners.reduce(into: Set<UUID>()) { ids, entry in
            if entry.key.resolvingSymlinksInPath() == path { ids.formUnion(entry.value) }
        }
        let targets = await store.deletionTargets(for: audioURL, recordingIDs: ids)
        try await lifecycle.removeSnapshots(for: audioURL)
        let base = audioURL.deletingPathExtension()
        var candidates = [audioURL] + ["md", "transcript.json", "richtranscript.json", "insights.json", "chat.json",
            "spokensummary.json", "spokensummary.m4a", "reprocessing.json", "json", "queue.json"].map { base.appendingPathExtension($0) }
        let prefix = base.lastPathComponent + "_part"
        let siblings = try fm.contentsOfDirectory(at: base.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        candidates += siblings.filter {
            let stem = $0.deletingPathExtension().lastPathComponent
            return RecordingDiscovery.supportedExtensions.contains($0.pathExtension.lowercased()) && stem.hasPrefix(prefix)
                && !stem.dropFirst(prefix.count).isEmpty && stem.dropFirst(prefix.count).allSatisfy(\.isNumber)
        }
        var deletionError: (any Error)?
        for url in candidates where fm.fileExists(atPath: url.path) {
            do { try fm.removeItem(at: url) }
            catch { deletionError = deletionError ?? error }
        }
        do {
            if try !PrivacyReceiptLifecycle.hasSurvivingAudio(for: PrivacyReceiptLifecycle.receiptURL(for: audioURL), fileManager: fm) {
                try await store.removeEvidence(at: targets)
            }
        } catch { deletionError = deletionError ?? error }
        if let deletionError { throw deletionError }
    }

    func retentionOwnership(folders: [URL]) throws -> (Date, RetentionOwnership) {
        try RetentionOwnership.preflight(folders: folders)
        let value = RetentionOwnership(folders: folders)
        guard !value.inspectionFailed else { throw LiveArtifactError.artifactTooLarge }
        return (now(), value)
    }

    func validateRetentionFolders(_ folders: [URL]) throws { try RetentionOwnership.preflight(folders: folders) }

    func retentionQueueBases(folders: [URL]) throws -> Set<String> {
        try RetentionOwnership.preflight(folders: folders)
        return Set(RetentionOwnership.regularFiles(in: folders).filter { $0.lastPathComponent.hasSuffix(".queue.json") }
            .map { RetentionCleanup.canonicalBase($0.deletingPathExtension().deletingPathExtension()) })
    }

    func cleanupRetention(category: RetentionCategory, days: Int, folders: [URL], lifecycle: RecoveryLifecycle,
                          store: PrivacyReceiptStore = .shared, protectedBases: Set<String> = []) async throws -> RetentionCleanupResult {
        let timestamp = now()
        try RetentionOwnership.preflight(folders: folders)
        let owners = try await lifecycle.privacyOwners(bounded: true)
        let protected = try await lifecycle.prepareRetention(category: category, days: days, folders: folders, now: timestamp, protectedBases: protectedBases, bounded: true)
        return await RetentionCleanup.cleanupWithPrivacy(category: category, olderThanDays: days, in: folders,
            store: store, now: timestamp, protectedBases: protected, extraRecordingIDs: owners, bounded: true)
    }
}
