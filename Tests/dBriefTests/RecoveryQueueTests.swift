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
            bundle: .init(title: "Meeting", createdAt: job.createdAt, durationSeconds: 1,
                audioFileURL: URL(fileURLWithPath: job.source.finalizedAudioPath!), transcript: "Private text",
                summary: nil, actionItems: [], tags: [], sentiment: nil, markdown: nil, calendarEvent: nil),
            deliveries: [.init(id: UUID(), destination: .webhook, configurationDigest: "target")])
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

    @Test func queueOrderAndPauseSurviveRestartWithoutChangingIntent() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"))
        let original = QueueItem(transcribe: true, summary: false, actionItems: true, tags: false, autoQueued: true)
        let bytes = try JSONEncoder().encode(original)
        let marker = root.appendingPathComponent("meeting.queue.json")
        try bytes.write(to: marker)
        var schedule = try store.load()
        schedule.paused = true
        schedule.order = ["b", "a"]
        try store.save(schedule)
        #expect(try QueueScheduleStore(url: store.url).load() == schedule)
        #expect(try Data(contentsOf: marker) == bytes)
    }

    @Test func invalidAndFutureSchedulesAreNeverOverwritten() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"))
        for bytes in [Data("broken".utf8), Data(#"{"version":99,"paused":false,"order":[]}"#.utf8)] {
            try bytes.write(to: store.url)
            #expect(throws: (any Error).self) { try store.save(QueueSchedule()) }
            #expect(try Data(contentsOf: store.url) == bytes)
        }
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
        let discovered = RecordingManager.discoverQueuedItems(in: root)
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
        #expect(RecordingManager.discoverQueuedItems(in: root).count == 1)
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
        try schedule.save(QueueSchedule(order: [audio.path]))
        try await schedule.removeQueuedItem(at: audio, lifecycle: RecoveryLifecycle(jobs: jobs, deliveries: deliveries))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: audio) == Data("audio".utf8))
        #expect(try await jobs.load(id: record.id)?.launchRecoveryAction == PersistedProcessingJob.LaunchRecoveryAction.none)
        #expect(try await jobs.load(id: record.id)?.dismissedFromQueue == true)
        #expect(try await deliveries.load(id: record.id)?.dismissedFromQueue == true)
        #expect(try schedule.load().order.isEmpty)
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
