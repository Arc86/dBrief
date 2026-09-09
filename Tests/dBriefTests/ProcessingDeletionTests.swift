import Foundation
import Testing
@testable import dBrief

@Suite("Processing deletion and retention")
struct ProcessingDeletionTests {
    private struct Fixture {
        let root: URL
        let library: URL
        let store: PrivacyReceiptStore
        let lifecycle: RecoveryLifecycle
        let journal: DurabilityJournal
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("processing-deletion-\(UUID())")
            library = root.appendingPathComponent("library")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            store = PrivacyReceiptStore(gapDirectoryURL: root.appendingPathComponent("gaps"),
                                        pendingDirectoryURL: root.appendingPathComponent("pending"))
            lifecycle = RecoveryLifecycle(jobs: ProcessingJobStore(rootURL: root.appendingPathComponent("jobs")),
                deliveries: IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries")))
            journal = DurabilityJournal(directoryURL: root.appendingPathComponent("diagnostics"))
        }
        var audio: URL { library.appendingPathComponent("meeting.m4a") }
        var receipt: URL { PrivacyReceiptStore.sidecarURL(for: audio) }
        func clean() { try? FileManager.default.removeItem(at: root) }
        func write(_ url: URL) throws { try Data([1, 2, 3]).write(to: url) }
        func scope(id: UUID = UUID()) -> RecordingPrivacyScope {
            RecordingPrivacyScope(recordingID: id, store: store, pendingRootURL: root.appendingPathComponent("pending"))
        }
        func files(_ manager: ProbeFiles = ProbeFiles()) -> ProcessingPipeline.DeletionFiles {
            .init(fileManager: { manager }, record: { event in
                #expect(!Thread.isMainThread)
                journal.record(event)
            })
        }
    }
    private final class ProbeFiles: FileManager, @unchecked Sendable {
        let failedRemoval: URL?
        let failInspectionAfterRemoval: URL?
        init(failedRemoval: URL? = nil, failInspectionAfterRemoval: URL? = nil) {
            self.failedRemoval = failedRemoval
            self.failInspectionAfterRemoval = failInspectionAfterRemoval
            super.init()
        }
        override func fileExists(atPath path: String) -> Bool {
            #expect(!Thread.isMainThread)
            return super.fileExists(atPath: path)
        }
        override func removeItem(at url: URL) throws {
            #expect(!Thread.isMainThread)
            if url == failedRemoval { throw CocoaError(.fileWriteNoPermission) }
            try super.removeItem(at: url)
        }
        override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                          options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
            #expect(!Thread.isMainThread)
            if let audio = failInspectionAfterRemoval, !super.fileExists(atPath: audio.path) {
                throw CocoaError(.fileReadNoPermission)
            }
            return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        }
    }
    private var operation: PrivacyOperation {
        .init(stage: .transcription, data: [.recordingAudio], destination: .local(provider: .whisper))
    }
    private func job(_ audio: URL, dismissed: Bool = false) -> PersistedProcessingJob {
        let date = Date(timeIntervalSince1970: 100)
        var value = PersistedProcessingJob(id: UUID(), recordingID: UUID(), createdAt: date, updatedAt: date,
            status: .failed,
            request: .init(transcribe: true, summary: false, actionItems: false, tags: false,
                           titleWasUserProvided: false, autoResume: true),
            source: .init(recordingDate: date, duration: 1, fileSize: 3, meetingTitle: "Fixture", participants: [],
                          echoSuppressionApplied: false, finalizedAudioPath: audio.path, segmentAudioPaths: []))
        value.dismissedFromQueue = dismissed
        return value
    }

    @Test @MainActor func historyDeletionRetiresAllArtifactsAndUnboundJournalOwnedEvidence() async throws {
        let f = try Fixture(); defer { f.clean() }
        let record = job(f.audio)
        try await f.lifecycle.jobs.save(record)
        let scope = f.scope(id: record.recordingID)
        let token = await PrivacyTrace.begin(operation, in: await scope.context())
        let suffixes = ["m4a", "md", "transcript.json", "richtranscript.json", "insights.json", "chat.json",
                        "spokensummary.json", "spokensummary.m4a", "json", "queue.json"]
        let owned = suffixes.map { f.audio.deletingPathExtension().appendingPathExtension($0) }
            + [f.library.appendingPathComponent("meeting_part01.flac")]
        let unrelated = ["meeting_partnotes.m4a", "meeting_part.m4a", "meeting_other.m4a"].map {
            f.library.appendingPathComponent($0)
        }
        for url in owned + unrelated { try f.write(url) }
        try await ProcessingPipeline().deleteRecordingFiles(f.audio, lifecycle: f.lifecycle, store: f.store, files: f.files())
        for url in owned { #expect(!FileManager.default.fileExists(atPath: url.path)) }
        for url in unrelated { #expect(try Data(contentsOf: url) == Data([1, 2, 3])) }
        #expect(try await f.lifecycle.jobs.load(id: record.id) == nil)
        // Only the journal knew this pending receipt's owner. It must be found
        // before snapshot deletion, then suppressed against late completion.
        await PrivacyTrace.finish(token, outcome: .succeeded)
        #expect(!FileManager.default.fileExists(atPath: scope.pendingReceiptURL.path))
        #expect(try await f.store.begin(operation, runID: UUID(), at: scope.pendingReceiptURL) == nil)
    }

    @Test(arguments: [false, true]) func corruptSnapshotBlocksDeletionAndRetention(retention: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write(f.audio)
        let record = job(f.audio)
        try await f.lifecycle.jobs.save(record)
        let manifest = f.root.appendingPathComponent("jobs/\(record.id.uuidString.lowercased())/job.json")
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: manifest)
        _ = try await f.store.begin(operation, runID: UUID(), at: f.receipt)
        let receiptBytes = try Data(contentsOf: f.receipt)
        await #expect(throws: (any Error).self) {
            let pipeline = ProcessingPipeline(now: { .distantFuture })
            if retention {
                _ = try await pipeline.cleanupRetention(category: .recordings, days: 0, folders: [f.library],
                                                        lifecycle: f.lifecycle, store: f.store)
            } else {
                try await pipeline.deleteRecordingFiles(f.audio, lifecycle: f.lifecycle, store: f.store, files: f.files())
            }
        }
        #expect(try Data(contentsOf: manifest) == corrupt)
        #expect(try Data(contentsOf: f.receipt) == receiptBytes)
        #expect(try Data(contentsOf: f.audio) == Data([1, 2, 3]))
    }

    @Test @MainActor func failedAudioRemovalKeepsEvidenceAndContinuesOtherDeletes() async throws {
        let f = try Fixture(); defer { f.clean() }
        let metadata = f.audio.deletingPathExtension().appendingPathExtension("json")
        let segment = f.library.appendingPathComponent("meeting_part01.m4a")
        for url in [f.audio, metadata, segment] { try f.write(url) }
        let scope = f.scope()
        let token = await PrivacyTrace.begin(operation, in: await scope.context())
        await scope.bind(to: f.audio)
        do {
            try await ProcessingPipeline().deleteRecordingFiles(f.audio, lifecycle: f.lifecycle, store: f.store,
                files: f.files(ProbeFiles(failedRemoval: f.audio)))
            Issue.record("Expected the audio deletion error")
        } catch { #expect((error as NSError).code == CocoaError.fileWriteNoPermission.rawValue) }
        #expect(FileManager.default.fileExists(atPath: f.audio.path))
        #expect(!FileManager.default.fileExists(atPath: metadata.path))
        #expect(!FileManager.default.fileExists(atPath: segment.path))
        await PrivacyTrace.finish(token, outcome: .succeeded)
        #expect(try await f.store.load(from: f.receipt)?.attempts.first?.outcome == .succeeded)
    }

    @Test func unavailableFolderAfterDeletionKeepsPrivacyEvidence() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write(f.audio)
        _ = try await f.store.begin(operation, runID: UUID(), at: f.receipt)
        let evidence = try Data(contentsOf: f.receipt)
        await #expect(throws: (any Error).self) {
            try await ProcessingPipeline().deleteRecordingFiles(f.audio, lifecycle: f.lifecycle, store: f.store,
                files: f.files(ProbeFiles(failInspectionAfterRemoval: f.audio)))
        }
        #expect(!FileManager.default.fileExists(atPath: f.audio.path))
        #expect(try Data(contentsOf: f.receipt) == evidence)
    }

    @Test func anotherMasterFormatPreservesSharedEvidence() async throws {
        let f = try Fixture(); defer { f.clean() }
        let otherMaster = f.audio.deletingPathExtension().appendingPathExtension("wav")
        for url in [f.audio, otherMaster] { try f.write(url) }
        _ = try await f.store.begin(operation, runID: UUID(), at: f.receipt)
        try await ProcessingPipeline().deleteRecordingFiles(f.audio, lifecycle: f.lifecycle, store: f.store, files: f.files())
        #expect(!FileManager.default.fileExists(atPath: f.audio.path))
        #expect(FileManager.default.fileExists(atPath: otherMaster.path))
        #expect(try await f.store.load(from: f.receipt) != nil)
    }

    @Test @MainActor func discardFinishesCancelledCleanupAndSuppressesPendingEvidence() async throws {
        let f = try Fixture(); defer { f.clean() }
        let scope = f.scope()
        let context = await scope.context()
        let token = await PrivacyTrace.begin(operation, in: context)
        let session = try InterruptedSessionStore.createSession(id: scope.recordingID, startedAt: .distantPast,
                                                               rootURL: f.root.appendingPathComponent("recovery"))
        let raw = session.directoryURL.appendingPathComponent("capture.mic.caf")
        try f.write(raw)
        let request = ProcessingPipeline.DiscardRequest(recordingID: scope.recordingID,
            recoveryManifestURL: session.manifestURL, audioURL: session.captureBaseURL, finalized: false,
            knownFiles: [session.captureBaseURL, raw], pendingReceiptURL: scope.pendingReceiptURL)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await PrivacyTrace.$context.withValue(context) {
                await ProcessingPipeline().discardRecordingFiles(request, store: f.store, files: f.files())
            }
        }
        await task.value
        #expect(!FileManager.default.fileExists(atPath: session.directoryURL.path))
        await PrivacyTrace.finish(token, outcome: .succeeded)
        #expect(!FileManager.default.fileExists(atPath: scope.pendingReceiptURL.path))
        #expect(try await f.store.begin(operation, runID: UUID(), at: scope.pendingReceiptURL) == nil)
        #expect(f.journal.recentEvents().map(\.name) == ["recording_discarded_by_user"])
    }

    @Test func failedDiscardRetainsAudioEvidenceAndReportsRecoveryWarning() async throws {
        let f = try Fixture(); defer { f.clean() }
        let scope = f.scope()
        let token = await PrivacyTrace.begin(operation, in: await scope.context())
        await scope.bind(to: f.audio)
        try f.write(f.audio)
        let missingManifest = f.root.appendingPathComponent("absent/manifest.json")
        await ProcessingPipeline().discardRecordingFiles(.init(recordingID: scope.recordingID,
            recoveryManifestURL: missingManifest, audioURL: f.audio, finalized: true,
            knownFiles: [f.audio], pendingReceiptURL: scope.pendingReceiptURL), store: f.store,
            files: f.files(ProbeFiles(failedRemoval: f.audio)))
        #expect(FileManager.default.fileExists(atPath: f.audio.path))
        await PrivacyTrace.finish(token, outcome: .succeeded)
        #expect(try await f.store.load(from: f.receipt)?.attempts.first?.outcome == .succeeded)
        #expect(f.journal.recentEvents().map(\.outcome) == [.warning, .succeeded])
    }

    @Test @MainActor func retentionProtectsPendingWorkAndRetiresDismissedOwnersBeforeEvidence() async throws {
        let f = try Fixture(); defer { f.clean() }
        let pending = job(f.library.appendingPathComponent("pending.m4a"))
        let dismissed = job(f.audio, dismissed: true)
        for record in [pending, dismissed] {
            try f.write(URL(fileURLWithPath: record.source.finalizedAudioPath!))
            try await f.lifecycle.jobs.save(record)
        }
        let scope = f.scope(id: dismissed.recordingID)
        let token = await PrivacyTrace.begin(operation, in: await scope.context())
        let future = Date().addingTimeInterval(10 * 86_400)
        let result = try await ProcessingPipeline(now: { future }).cleanupRetention(category: .recordings,
            days: 7, folders: [f.library], lifecycle: f.lifecycle, store: f.store)
        #expect(result.filesDeleted == 1)
        #expect(result.privacyCleanupFailures == 0)
        #expect(!FileManager.default.fileExists(atPath: f.audio.path))
        #expect(FileManager.default.fileExists(atPath: pending.source.finalizedAudioPath!))
        #expect(try await f.lifecycle.jobs.load(id: dismissed.id) == nil)
        #expect(try await f.lifecycle.jobs.load(id: pending.id) != nil)
        await PrivacyTrace.finish(token, outcome: .succeeded)
        #expect(!FileManager.default.fileExists(atPath: scope.pendingReceiptURL.path))
        #expect(try await f.store.begin(operation, runID: UUID(), at: scope.pendingReceiptURL) == nil)
    }
}
