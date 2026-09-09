import Foundation

/// Shared by a recording's capture, job, viewer and held speaker review. Each
/// invocation creates a new run ID while the store owns location changes.
struct RecordingPrivacyScope: Sendable {
    let recordingID: UUID
    let pendingReceiptURL: URL
    let store: PrivacyReceiptStore

    init(recordingID: UUID, store: PrivacyReceiptStore = .shared,
         pendingRootURL: URL = AppSupportPaths.subdirectory("Privacy Pending")) {
        self.pendingReceiptURL = pendingRootURL.appendingPathComponent(recordingID.uuidString + ".privacy.json")
        self.recordingID = recordingID
        self.store = store
    }

    func context(runID: UUID = UUID()) async -> PrivacyTrace.Context {
        do { try await store.preparePendingDirectory(at: pendingReceiptURL.deletingLastPathComponent()) }
        catch { await store.noteGap(at: pendingReceiptURL) }
        return PrivacyTrace.Context(receiptURL: pendingReceiptURL, store: store, runID: runID, recordingID: recordingID)
    }

    func bind(to audioURL: URL) async {
        let target = PrivacyReceiptStore.sidecarURL(for: audioURL)
        do { try await store.transfer(from: pendingReceiptURL, to: target) }
        catch {
            // Preserve pending evidence for a later retry and make the destination
            // visibly incomplete. Never replace unreadable existing evidence.
            await store.noteGap(at: target)
        }
    }
}

extension Recording {
    func privacyContext(runID: UUID = UUID()) async -> PrivacyTrace.Context {
        let stableID = finalizedAudioURL.flatMap { PrivacyReceiptLifecycle.recordingID(for: $0) } ?? id
        let scope = privacyScope ?? RecordingPrivacyScope(recordingID: stableID)
        privacyScope = scope
        let context = await scope.context(runID: runID)
        if let audio = finalizedAudioURL { await scope.bind(to: audio) }
        if !PrivacyTrace.coversAllProcessingStages { await scope.store.noteGap(at: scope.pendingReceiptURL) }
        return context
    }

    func bindPrivacyReceipt() async {
        guard let audio = finalizedAudioURL, let privacyScope else { return }
        await privacyScope.bind(to: audio)
    }
}
