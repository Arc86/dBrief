import Foundation
import Testing
@testable import dBrief

@Suite("Queue management and recovery lifecycle")
struct RecoveryQueueTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-queue-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func job(audio: URL, status: PersistedProcessingJob.Status = .failed) -> PersistedProcessingJob {
        let date = Date(timeIntervalSince1970: 100)
        return PersistedProcessingJob(id: UUID(), recordingID: UUID(), createdAt: date, updatedAt: date,
            status: status,
            request: .init(transcribe: true, summary: true, actionItems: false, tags: false, titleWasUserProvided: false, autoResume: true),
            source: .init(recordingDate: date, duration: 1, fileSize: 8, meetingTitle: "Meeting",
                participants: [], echoSuppressionApplied: false, finalizedAudioPath: audio.path, segmentAudioPaths: []))
    }
    private func batch(job: PersistedProcessingJob) -> IntegrationDeliveryBatch {
        IntegrationDeliveryBatch(id: job.id, recordingID: job.recordingID, createdAt: job.createdAt,
            bundle: .init(title: job.source.meetingTitle, createdAt: job.createdAt, durationSeconds: 1,
                audioFileURL: URL(fileURLWithPath: job.source.finalizedAudioPath!), transcript: "Private text",
                summary: nil, actionItems: [], tags: [], sentiment: nil, markdown: nil, calendarEvent: nil),
            deliveries: [.init(id: UUID(), destination: .webhook, configurationDigest: "target")])
    }

    @Test(arguments: [false, true]) func retentionRemovalCannotInheritAReplacedRecoveryManifest(delivery: Bool) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var record = job(audio: root.appendingPathComponent("audio.wav"), status: .completed)
        record.source.meetingTitle = String(repeating: "x", count: 20 * 1_024)
        if delivery {
            let store = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries"))
            let original = batch(job: record); try await store.save(original)
            let selected = try #require(try await store.retentionInventory().first)
            let file = selected.authority.manifest.url, bytes = try Data(contentsOf: file)
            try bytes.write(to: file, options: .atomic)
            await #expect(throws: LiveArtifactError.wrongOwner) { try await store.removeForRetention(id: original.id, expectedRecordingID: original.recordingID, expected: selected.authority) }
            #expect(try Data(contentsOf: file) == bytes)
            let renewed = try #require(try await store.retentionInventory().first)
            try await store.removeForRetention(id: original.id, expectedRecordingID: original.recordingID, expected: renewed.authority)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        } else {
            let store = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs")); try await store.save(record)
            let selected = try #require(try await store.retentionInventory().first)
            let file = selected.authority.manifest.url, bytes = try Data(contentsOf: file)
            try bytes.write(to: file, options: .atomic)
            await #expect(throws: LiveArtifactError.wrongOwner) { try await store.removeForRetention(id: record.id, expectedRecordingID: record.recordingID, expected: selected.authority) }
            #expect(try Data(contentsOf: file) == bytes)
            let renewed = try #require(try await store.retentionInventory().first)
            try await store.removeForRetention(id: record.id, expectedRecordingID: record.recordingID, expected: renewed.authority)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func retentionReplayFinishesFrozenScratchAfterItsManifestDisappears() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.wav"); try Data([1]).write(to: audio)
        let record = job(audio: audio, status: .completed)
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        let lifecycle = RecoveryLifecycle(jobs: jobs, deliveries: .init(rootURL: root.appendingPathComponent("deliveries")))
        try await jobs.save(record)
        let directory = root.appendingPathComponent("jobs/\(record.id.uuidString)")
        let child = directory.appendingPathComponent("original-private-scratch.bin")
        try Data("original scratch".utf8).write(to: child)
        let expected = try await lifecycle.deletionSnapshot(for: audio, byteLimit: RecordingDeletionAuthority.ticketLimit, retention: true)
        let authority = try RecordingDeletionAuthority(audioURL: audio, expectedRecordingID: record.recordingID)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("job.json"))
        await #expect(throws: Never.self, "Replay must finish original headerless scratch") {
            try await lifecycle.removeSnapshots(for: audio, expected: expected, authority: authority, retention: true)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await #expect(throws: Never.self, "A removed original inventory must remain idempotent") {
            try await lifecycle.removeSnapshots(for: audio, expected: expected, authority: authority, retention: true)
        }
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test(arguments: [false, true]) func retentionPhysicalRecordMustStillNameTheAuthorizedAudio(delivery: Bool) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("authorized.wav"); try Data([1]).write(to: audio)
        let record = job(audio: root.appendingPathComponent("foreign.wav"), status: .completed)
        let authority = try RecordingDeletionAuthority(audioURL: audio, expectedRecordingID: record.recordingID)
        if delivery {
            let store = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries")); try await store.save(batch(job: record))
            let frozen = try #require(try await store.retentionInventory().first)
            await #expect(throws: LiveArtifactError.wrongOwner) { try await store.removeForRetention(id: record.id,
                expectedRecordingID: record.recordingID, expected: frozen.authority, audioAuthority: authority) }
            #expect(FileManager.default.fileExists(atPath: frozen.authority.manifest.url.path))
        } else {
            let store = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs")); try await store.save(record)
            let frozen = try #require(try await store.retentionInventory().first)
            await #expect(throws: LiveArtifactError.wrongOwner) { try await store.removeForRetention(id: record.id,
                expectedRecordingID: record.recordingID, expected: frozen.authority, audioAuthority: authority) }
            #expect(FileManager.default.fileExists(atPath: frozen.authority.manifest.url.path))
        }
    }

    @Test func retentionTicketRejectsForeignRecoveryPrivacyOwners() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.wav"); try Data([1]).write(to: audio)
        let record = job(audio: audio, status: .completed)
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs")); try await jobs.save(record)
        let lifecycle = RecoveryLifecycle(jobs: jobs, deliveries: .init(rootURL: root.appendingPathComponent("deliveries")))
        let authority = try RecordingDeletionAuthority(audioURL: audio, expectedRecordingID: UUID())
        var ticket = ProcessingPipeline.FileDeletionTicket(authority: authority, items: [authority.audio],
            recoveryDirectory: nil, discard: nil, bytes: 512 + (try RecordingDeletionAuthority.charge(audio)) * 2)
        ticket.retentionCutoff = Date()
        ticket.snapshots = try await lifecycle.deletionSnapshot(for: audio, byteLimit: RecordingDeletionAuthority.ticketLimit, retention: true)
        #expect(throws: LiveArtifactError.wrongOwner) { try ticket.validateRetentionScope() }
    }

    @Test func retentionSnapshotEncodingIsStableThroughRepeatedColdDecodes() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pairs = (0..<8).map { _ in (UUID(), UUID()) }
        var physical: [UUID: RecoveryRetentionAuthority] = [:]
        for (id, _) in pairs {
            let file = root.appendingPathComponent(id.uuidString + ".json"); try Data("{}".utf8).write(to: file)
            physical[id] = try .init(manifest: .init(file))
        }
        let snapshot = RecoveryLifecycle.DeletionSnapshot(jobs: Dictionary(uniqueKeysWithValues: pairs),
            deliveries: Dictionary(uniqueKeysWithValues: pairs.reversed()), retentionJobs: physical, retentionDeliveries: physical)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(snapshot)
        for _ in 0..<32 {
            let decoded = try JSONDecoder().decode(RecoveryLifecycle.DeletionSnapshot.self, from: original)
            #expect(try encoder.encode(decoded) == original)
        }
        let legacy = try JSONSerialization.data(withJSONObject: ["jobs": pairs.flatMap { [$0.0.uuidString, $0.1.uuidString] },
            "deliveries": []])
        #expect(try JSONDecoder().decode(RecoveryLifecycle.DeletionSnapshot.self, from: legacy).jobs == snapshot.jobs)
        let duplicate = try JSONSerialization.data(withJSONObject: ["jobs": [pairs[0].0.uuidString, pairs[0].1.uuidString,
            pairs[0].0.uuidString, pairs[0].1.uuidString], "deliveries": []])
        #expect(throws: LiveArtifactError.wrongOwner) { _ = try JSONDecoder().decode(RecoveryLifecycle.DeletionSnapshot.self, from: duplicate) }
    }

    @Test func boundedRetentionPreservesCompletionJournalsWhileRecordingStorageIsOffline() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("offline-recordings")
        var record = job(audio: folder.appendingPathComponent("audio.wav"), status: .completed)
        record.completedAt = Date(timeIntervalSince1970: 200)
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs")); try await jobs.save(record)
        let manifest = root.appendingPathComponent("jobs/\(record.id.uuidString)/job.json"), bytes = try Data(contentsOf: manifest)
        let lifecycle = RecoveryLifecycle(jobs: jobs, deliveries: .init(rootURL: root.appendingPathComponent("deliveries")))
        await #expect(throws: (any Error).self) { _ = try await lifecycle.prepareRetention(category: .transcripts,
            days: 1, folders: [folder], now: Date(timeIntervalSince1970: 1_000_000), bounded: true) }
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        if FileManager.default.fileExists(atPath: manifest.path) { #expect(try Data(contentsOf: manifest) == bytes) }
    }

    @Test(arguments: [false, true]) func retentionRejectsAnOversizedRecoveryRecordBeforeReadingItsValue(delivery: Bool) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var record = job(audio: root.appendingPathComponent("audio.wav"), status: .completed)
        record.source.meetingTitle = String(repeating: "x", count: 130 * 1_024)
        if delivery {
            let store = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries")); try await store.save(batch(job: record))
            await #expect(throws: LiveArtifactError.artifactTooLarge) { _ = try await store.retentionInventory() }
        } else {
            let store = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs")); try await store.save(record)
            await #expect(throws: LiveArtifactError.artifactTooLarge) { _ = try await store.retentionInventory() }
        }
    }

    @Test func movingPreservesRelativeOrderAndHandlesBoundaries() {
        var schedule = QueueSchedule()
        schedule.move(path: "c", by: -2, currentPaths: ["a", "b", "c"])
        #expect(schedule.order == ["c", "a", "b"])
        schedule.move(path: "c", by: -1, currentPaths: schedule.order)
        #expect(schedule.order == ["c", "a", "b"])
        schedule.move(path: "missing", by: 1, currentPaths: schedule.order)
        #expect(schedule.order == ["c", "a", "b"])
        #expect(schedule.ordered(["a", "new", "c"], path: { $0 }) == ["c", "a", "new"])
        schedule.move(path: "c", by: 1, currentPaths: schedule.order)
        #expect(schedule.order == ["a", "c", "b"])
    }

    @Test func queueOrderAndPauseSurviveRestartWithoutChangingIntent() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"))
        let original = QueueItem(transcribe: true, summary: false, actionItems: true, tags: false, autoQueued: true)
        let bytes = try JSONEncoder().encode(original)
        let marker = root.appendingPathComponent("meeting.queue.json")
        try bytes.write(to: marker)
        var schedule = try await store.load()
        schedule.paused = true
        schedule.order = ["b", "a"]
        try await store.save(schedule)
        #expect(try await QueueScheduleStore(url: store.url).load() == schedule)
        #expect(try Data(contentsOf: marker) == bytes)
    }

    @Test func invalidAndFutureSchedulesAreNeverOverwritten() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"))
        for bytes in [Data("broken".utf8), Data(#"{"version":99,"paused":false,"order":[]}"#.utf8)] {
            try bytes.write(to: store.url)
            await #expect(throws: (any Error).self) { try await store.save(QueueSchedule()) }
            #expect(try Data(contentsOf: store.url) == bytes)
        }
    }

    @Test func queueRemainsDiscoverableAfterProfileFolderChangesAndRestart() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousFolder = root.appendingPathComponent("previous-profile")
        let currentFolder = root.appendingPathComponent("current-profile")
        try FileManager.default.createDirectory(at: previousFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentFolder, withIntermediateDirectories: true)
        let item = QueueItem(transcribe: true, summary: false, actionItems: false, tags: false, profileID: UUID())
        try JSONEncoder().encode(item).write(to: previousFolder.appendingPathComponent("queued.queue.json"))
        try Data("audio".utf8).write(to: previousFolder.appendingPathComponent("queued.m4a"))
        let store = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"))
        var schedule = try await store.load()
        schedule.rememberFolder(previousFolder)
        try await store.save(schedule)
        let reloaded = try await QueueScheduleStore(url: store.url).load()
        let folders = reloaded.discoveryFolders(configured: [currentFolder])
        let discovered = QueueScheduleStore.discoverQueuedItems(in: folders)
        #expect(discovered.map(\.item.id) == [item.id])
        // Overlapping configured roots cannot process one marker twice.
        #expect(QueueScheduleStore.discoverQueuedItems(in: folders + [root]).count == 1)
        let legacy = try JSONDecoder().decode(QueueSchedule.self, from: Data(#"{"version":1,"paused":false,"order":[]}"#.utf8))
        #expect(legacy.knownFolders == nil)
        #expect(legacy.discoveryFolders(configured: [currentFolder]).count == 1)
    }

    @Test func duplicateSavedPathsDoNotCrashSorting() {
        let schedule = QueueSchedule(order: ["b", "b", "stale"])
        #expect(schedule.ordered(["a", "b", "c"], path: { $0 }) == ["b", "a", "c"])
    }

    @Test func unifiedRecoveryIncludesOlderDeliveryRunsAndDeduplicatesQueue() {
        let audio = URL(fileURLWithPath: "/tmp/meeting.m4a")
        let old = job(audio: audio)
        let recent = job(audio: audio, status: .completed)
        let pending = job(audio: URL(fileURLWithPath: "/tmp/pending.m4a"))
        let entries = RecoveryQueueEntry.entries(jobs: [old, recent, pending], deliveries: [batch(job: old)], queuedIDs: [pending.id], activeID: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.id == old.id)
        #expect(entries.first?.isDelivery == true)
        #expect(RecoveryQueueEntry.entries(jobs: [old], deliveries: [], queuedIDs: [], activeID: old.id).isEmpty)
    }

    @Test func dismissedWorkStaysDismissedAfterRestart() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        var record = job(audio: root.appendingPathComponent("audio.m4a"), status: .running)
        record.dismissedFromQueue = true
        record.markCancelled(at: Date())
        try await store.save(record)
        let loaded = try #require(try await store.load(id: record.id))
        #expect(loaded.launchRecoveryAction == .none)
        #expect(RecoveryQueueEntry.entries(jobs: [loaded], deliveries: [batch(job: loaded)], queuedIDs: [], activeID: nil).isEmpty)
    }

    @Test func snapshotDeletionMatchesAllRunsButKeepsOtherRecordingsAndAudio() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        let deliveries = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries"))
        let audio = root.appendingPathComponent("audio.m4a")
        try Data("audio".utf8).write(to: audio)
        let first = job(audio: audio)
        let second = job(audio: audio)
        let other = job(audio: root.appendingPathComponent("other.m4a"))
        for record in [first, second, other] {
            try await jobs.save(record)
            try await deliveries.save(batch(job: record))
        }
        try await RecoveryLifecycle(jobs: jobs, deliveries: deliveries).removeSnapshots(for: audio)
        #expect(await jobs.discover().jobs.map(\.id) == [other.id])
        #expect(try await deliveries.discover().map(\.id) == [other.id])
        #expect(try Data(contentsOf: audio) == Data("audio".utf8))
    }

    @Test func corruptSnapshotBlocksCleanupWithoutDeletingValidData() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobRoot = root.appendingPathComponent("jobs")
        let jobs = ProcessingJobStore(rootURL: jobRoot)
        let deliveries = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries"))
        let record = job(audio: root.appendingPathComponent("audio.m4a"))
        try await jobs.save(record)
        let manifest = jobRoot.appendingPathComponent(record.id.uuidString.lowercased()).appendingPathComponent("job.json")
        let bytes = Data("broken".utf8)
        try bytes.write(to: manifest)
        await #expect(throws: (any Error).self) {
            try await RecoveryLifecycle(jobs: jobs, deliveries: deliveries).removeSnapshots(for: URL(fileURLWithPath: record.source.finalizedAudioPath!))
        }
        #expect(try Data(contentsOf: manifest) == bytes)
    }

    @Test func retentionProtectsUnfinishedWorkAndExpiresDismissedSnapshots() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        let deliveries = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries"))
        let pending = job(audio: library.appendingPathComponent("pending.m4a"))
        var dismissed = job(audio: library.appendingPathComponent("dismissed.m4a"))
        dismissed.dismissedFromQueue = true
        let completed = job(audio: library.appendingPathComponent("complete.m4a"), status: .completed)
        let outside = job(audio: root.appendingPathComponent("elsewhere/audio.m4a"), status: .completed)
        for record in [pending, dismissed, completed, outside] { try await jobs.save(record) }
        try await deliveries.save(batch(job: pending))
        let lifecycle = RecoveryLifecycle(jobs: jobs, deliveries: deliveries)
        let protected = try await lifecycle.prepareRetention(category: .transcripts, days: 1, folders: [library], now: Date(timeIntervalSince1970: 1_000_000))
        #expect(protected.contains(library.resolvingSymlinksInPath().appendingPathComponent("pending").path))
        #expect(try await jobs.load(id: dismissed.id) == nil)
        #expect(try await jobs.load(id: completed.id) == nil)
        #expect(try await jobs.load(id: outside.id) != nil)
        #expect(try await deliveries.load(id: pending.id) != nil)
        let raw = library.appendingPathComponent("pending.transcript.json")
        try Data("private transcript".utf8).write(to: raw)
        let result = RetentionCleanup.cleanup(category: .transcripts, olderThanDays: 0, in: [library], now: Date().addingTimeInterval(100), protectedBases: protected)
        #expect(result.filesDeleted == 0, "Protected bases: \(protected)")
        #expect(FileManager.default.fileExists(atPath: raw.path))
    }

    @Test func queueDiscoverySupportsImportedWavFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = QueueItem(transcribe: true, summary: false, actionItems: false, tags: false)
        try JSONEncoder().encode(item).write(to: root.appendingPathComponent("import.queue.json"))
        try Data("audio".utf8).write(to: root.appendingPathComponent("import.wav"))
        let discovered = QueueScheduleStore.discoverQueuedItems(in: root)
        #expect(discovered.count == 1)
        #expect(discovered.first?.audioURL.pathExtension == "wav")
        #expect(discovered.first?.item.id == item.id)
    }

    @Test func legacyQueueIdentityIsStableAcrossScansWithoutRewritingIt() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("legacy.queue.json")
        let bytes = Data(#"{"transcribe":true,"summary":false,"actionItems":false,"tags":false}"#.utf8)
        try bytes.write(to: marker)
        #expect(try QueueItem.load(from: marker).id == QueueItem.load(from: marker).id)
        #expect(try Data(contentsOf: marker) == bytes)
        // A missing master remains visible and removable instead of vanishing.
        #expect(QueueScheduleStore.discoverQueuedItems(in: root).count == 1)
    }

    @Test func queueRemovalRetiresIntentAndSuppressesRecoveryButKeepsAudio() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("meeting.m4a")
        let marker = root.appendingPathComponent("meeting.queue.json")
        try Data("audio".utf8).write(to: audio)
        let record = job(audio: audio, status: .running)
        let item = QueueItem(id: record.id, transcribe: true, summary: true, actionItems: false, tags: false, autoQueued: true)
        try JSONEncoder().encode(item).write(to: marker)
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        let deliveries = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries"))
        try await jobs.save(record)
        try await deliveries.save(batch(job: record))
        let schedule = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"))
        try await schedule.save(QueueSchedule(order: [audio.path]))
        try await schedule.removeQueuedItem(at: audio, lifecycle: RecoveryLifecycle(jobs: jobs, deliveries: deliveries))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: audio) == Data("audio".utf8))
        #expect(try await jobs.load(id: record.id)?.launchRecoveryAction == PersistedProcessingJob.LaunchRecoveryAction.none)
        #expect(try await jobs.load(id: record.id)?.dismissedFromQueue == true)
        #expect(try await deliveries.load(id: record.id)?.dismissedFromQueue == true)
        #expect(try await schedule.load().order.isEmpty)
    }

    @Test func failedRemovalLeavesMarkerDeferredAndAudioUntouched() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("meeting.m4a")
        let marker = root.appendingPathComponent("meeting.queue.json")
        try Data("audio".utf8).write(to: audio)
        let record = job(audio: audio, status: .running)
        let item = QueueItem(id: record.id, transcribe: true, summary: true, actionItems: false, tags: false, autoQueued: true)
        try JSONEncoder().encode(item).write(to: marker)
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        let deliveryRoot = root.appendingPathComponent("deliveries")
        let deliveries = IntegrationDeliveryStore(rootURL: deliveryRoot)
        try await jobs.save(record)
        try await deliveries.save(batch(job: record))
        let deliveryFile = deliveryRoot.appendingPathComponent(record.id.uuidString.lowercased()).appendingPathExtension("json")
        try Data("corrupt".utf8).write(to: deliveryFile)
        let schedule = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"))
        await #expect(throws: (any Error).self) {
            try await schedule.removeQueuedItem(at: audio, lifecycle: RecoveryLifecycle(jobs: jobs, deliveries: deliveries))
        }
        #expect(try QueueItem.load(from: marker).autoQueued == false)
        #expect(try Data(contentsOf: audio) == Data("audio".utf8))
        #expect(try Data(contentsOf: deliveryFile) == Data("corrupt".utf8))
    }

    @Test func completedDeliveryBoundaryNeedsNoAttentionAndCanExpire() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        let deliveries = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries"))
        var record = job(audio: root.appendingPathComponent("meeting.m4a"), status: .markdownComplete)
        _ = record.markCompleted(.markdownGenerated, at: record.updatedAt)
        var saved = batch(job: record)
        saved.deliveries = [] // No configured integration is a completed delivery batch.
        try await jobs.save(record)
        try await deliveries.save(saved)
        #expect(RecoveryQueueEntry.entries(jobs: [record], deliveries: [saved], queuedIDs: [], activeID: nil).isEmpty)
        let protected = try await RecoveryLifecycle(jobs: jobs, deliveries: deliveries)
            .prepareRetention(category: .transcripts, days: 1, folders: [root], now: Date(timeIntervalSince1970: 1_000_000))
        #expect(protected.isEmpty)
        #expect(try await jobs.load(id: record.id) == nil)
        #expect(try await deliveries.load(id: record.id) == nil)
    }
}
