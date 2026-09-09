import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Processing cancellation durability")
struct ProcessingCancellationTests {
    private actor Audit {
        var calls: [String] = []
        var saved: PersistedProcessingJob?
        var queued: QueueItem?
        func add(_ call: String) { calls.append(call) }
        func save(_ record: PersistedProcessingJob) { saved = record; calls.append("save") }
        func queue(_ item: QueueItem) { queued = item; calls.append("queue") }
    }
    private func record() -> PersistedProcessingJob {
        .init(id: UUID(), recordingID: UUID(), createdAt: .distantPast, updatedAt: .distantPast,
            status: .running, request: .init(transcribe: true, summary: false, actionItems: true, tags: false,
                titleWasUserProvided: true, autoResume: true),
            source: .init(recordingDate: .distantPast, duration: 3, fileSize: 10, meetingTitle: "Fixture", associatedApp: nil,
                participants: [], calendarEvent: nil, echoSuppressionApplied: false, recoveryManifestPath: nil,
                stagedInputPath: nil, finalizedAudioPath: "/synthetic/audio.m4a", segmentAudioPaths: [], metadataPath: nil,
                profileID: UUID()))
    }
    private func snapshot(_ record: PersistedProcessingJob) -> ProcessingPipeline.CancellationSnapshot {
        .init(jobID: record.id, source: record.source, fallbackRecord: record, queuedAudioURL: nil,
            transcriptURL: nil, fallbackQueueItem: .init(id: record.id, transcribe: false, summary: true,
                actionItems: false, tags: true, profileID: UUID()))
    }
    private func steps(_ record: PersistedProcessingJob, audit: Audit) -> ProcessingPipeline.CancellationSteps {
        .init(releaseResources: { await audit.add("release") }, waitForJob: { await audit.add("unwind") },
            snapshot: { await audit.add("snapshot"); return snapshot(record) },
            loadRecord: { id in #expect(id == record.id); await audit.add("load"); return record },
            saveRecord: { await audit.save($0) }, publishRecord: { _ in await audit.add("publish") },
            registerQueueFolder: { _ in await audit.add("register") },
            warning: { await audit.add($0 == .journal ? "journalWarning" : "queueWarning") })
    }
    private func files(_ audit: Audit) -> ProcessingPipeline.CancellationFiles {
        .init(readQueue: { _ in nil }, writeQueue: { item, _ in await audit.queue(item) })
    }

    @Test func unwindPrecedesSnapshotAndLatestCheckpointIsPreserved() async throws {
        let original = record(), audit = Audit()
        var latest = original
        _ = latest.markCompleted(.audioFinalized, at: Date(timeIntervalSince1970: 100))
        latest.speakerReviewRequired = true
        let durable = latest
        var actions = steps(original, audit: audit)
        actions.snapshot = {
            #expect(await audit.calls == ["release", "unwind"])
            return snapshot(original)
        }
        actions.loadRecord = { _ in await audit.add("load"); return durable }
        try await ProcessingPipeline().cancelWorkflow(steps: actions, files: files(audit))
        let saved = try #require(await audit.saved)
        #expect(saved.status == .cancelled)
        #expect(saved.checkpoint == durable.checkpoint && saved.speakerReviewRequired == true)
        let queued = await audit.queued
        #expect(queued?.summary == false && queued?.actionItems == true)
        #expect(await audit.queued?.profileID == original.source.profileID)
        #expect(await audit.calls == ["release", "unwind", "load", "save", "publish", "register", "queue"])
    }

    @Test func initialCreateAndDurablePathsSurviveMissingMemorySnapshot() async throws {
        let original = record(), audit = Audit()
        var actions = steps(original, audit: audit)
        actions.snapshot = {
            var input = snapshot(original)
            input.fallbackRecord = nil
            input.source.finalizedAudioPath = nil
            input.source.fileSize = 0
            return input
        }
        try await ProcessingPipeline().cancelWorkflow(steps: actions, files: files(audit))
        #expect(await audit.saved?.source.finalizedAudioPath == original.source.finalizedAudioPath)
        #expect(await audit.saved?.source.fileSize == original.source.fileSize)
        #expect(await audit.queued != nil)
    }

    @Test func unreadableJournalIsRetainedWhileQueueFallbackStillRuns() async throws {
        let original = record(), audit = Audit()
        var actions = steps(original, audit: audit)
        actions.loadRecord = { _ in throw CocoaError(.coderReadCorrupt) }
        try await ProcessingPipeline().cancelWorkflow(steps: actions, files: files(audit))
        #expect(await audit.saved == nil)
        #expect(await audit.queued?.autoQueued == false)
        #expect(await audit.calls == ["release", "unwind", "snapshot", "journalWarning", "register", "queue"])
    }

    @Test(arguments: [false, true])
    func existingMarkerRetainsIntentAndDifferentIdentityIsNeverOverwritten(conflict: Bool) async throws {
        let original = record(), audit = Audit()
        let marker = QueueItem(id: conflict ? UUID() : original.id, transcribe: false, summary: true,
            actionItems: false, tags: true, autoQueued: true, profileID: UUID())
        var storage = files(audit)
        storage.readQueue = { _ in marker }
        try await ProcessingPipeline().cancelWorkflow(steps: steps(original, audit: audit), files: storage)
        if conflict {
            #expect(await audit.queued == nil)
            #expect(await audit.calls.last == "queueWarning")
        } else {
            let queued = await audit.queued
            #expect(queued?.id == marker.id && queued?.profileID == marker.profileID)
            #expect(queued?.summary == true && queued?.transcribe == false)
            #expect(await audit.queued?.autoQueued == false)
        }
    }

    @Test func callerCancellationStillFinishesOwnedCleanup() async throws {
        let original = record(), audit = Audit()
        var actions = steps(original, audit: audit)
        actions.releaseResources = { withUnsafeCurrentTask { $0?.cancel() }; await audit.add("release") }
        let input = actions
        try await Task { try await ProcessingPipeline().cancelWorkflow(steps: input, files: files(audit)) }.value
        #expect(await audit.saved?.status == .cancelled)
        #expect(await audit.queued != nil)
    }

    @Test func replacementAfterFolderRegistrationStopsMarkerWrite() async throws {
        let original = record(), audit = Audit()
        var actions = steps(original, audit: audit)
        actions.validateOwnership = {
            if await audit.calls.contains("register") { throw CancellationError() }
        }
        await #expect(throws: CancellationError.self) {
            try await ProcessingPipeline().cancelWorkflow(steps: actions, files: files(audit))
        }
        #expect(await audit.queued == nil)
    }

    @Test func legacyJournalRetainsProfileFrozenBeforeStop() async throws {
        var original = record()
        original.source.profileID = nil
        let legacy = original, audit = Audit()
        let input = snapshot(legacy)
        var actions = steps(legacy, audit: audit)
        actions.snapshot = {
            var changed = input
            changed.source.profileID = UUID() // settings selected during unwind
            return changed
        }
        try await ProcessingPipeline().cancelWorkflow(steps: actions, files: files(audit))
        #expect(await audit.saved?.source.profileID == input.fallbackQueueItem.profileID)
        #expect(await audit.queued?.profileID == input.fallbackQueueItem.profileID)
    }

    @Test @MainActor func committedFinalizerHandoffIsQueuedAfterWorkerFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = root.appendingPathComponent("scratch.caf"), audio = root.appendingPathComponent("final.m4a")
        try Data("synthetic audio".utf8).write(to: scratch)
        let store = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        var original = record()
        original.source.finalizedAudioPath = nil
        original.source.stagedInputPath = scratch.path
        let stale = original
        try await store.save(stale)
        let recording = Recording(fileURL: scratch, duration: 3)
        let job = ProcessingJob(id: stale.id, recording: recording)
        job.persistedRecord = stale
        // A committed finalizer hands off its output even when Stop has arrived.
        job.task = Task { @MainActor in
            do {
                try FileManager.default.copyItem(at: scratch, to: audio)
                try FileManager.default.removeItem(at: scratch)
                recording.fileURL = audio
                recording.finalizedAudioURL = audio
                var durable = stale
                durable.source.finalizedAudioPath = audio.path
                durable.source.stagedInputPath = nil
                _ = durable.markCompleted(.audioFinalized, at: Date(timeIntervalSince1970: 100))
                try await store.save(durable)
                // Stop prevented the checkpoint acknowledgement on the UI job.
            } catch { Issue.record("Synthetic finalizer failed: \(error)") }
        }
        job.task?.cancel()
        let audit = Audit()
        let scheduleStore = QueueScheduleStore(url: root.appendingPathComponent("schedule.json"))
        var actions = steps(stale, audit: audit)
        actions.waitForJob = { @MainActor in await job.task?.value }
        actions.snapshot = { @MainActor in
            #expect(recording.finalizedAudioURL == audio)
            var input = snapshot(stale)
            input.source.finalizedAudioPath = recording.finalizedAudioURL?.path
            input.source.stagedInputPath = nil
            return input
        }
        actions.loadRecord = { try await store.load(id: $0) }
        actions.saveRecord = { try await store.save($0) }
        actions.publishRecord = { @MainActor in job.persistedRecord = $0 }
        actions.registerQueueFolder = { @MainActor folder in
            try await scheduleStore.rememberFolder(folder)
        }
        try await ProcessingPipeline().cancelWorkflow(steps: actions)
        let saved = try #require(try await store.load(id: stale.id))
        #expect(saved.status == .cancelled && saved.checkpoint.hasCompleted(.audioFinalized))
        #expect(saved.source.finalizedAudioPath == audio.path && saved.source.stagedInputPath == nil)
        let marker = try QueueItem.load(from: audio.deletingPathExtension().appendingPathExtension("queue.json"))
        #expect(marker.id == job.id && !marker.autoQueued && marker.actionItems && !marker.summary)
        #expect(try Data(contentsOf: audio) == Data("synthetic audio".utf8))
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        #expect(try await scheduleStore.load().knownFolders?.contains(root.standardizedFileURL.path) == true)
    }

    @Test(arguments: [false, true], [false, true])
    func savedTranscriptSkipsNewMarkerButStillDefersExistingMarker(existing: Bool, cancelCaller: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.m4a")
        let transcript = root.appendingPathComponent("audio.transcript.json")
        let marker = root.appendingPathComponent("audio.queue.json")
        try Data("audio".utf8).write(to: audio)
        try JSONEncoder().encode(TranscriptionResult(text: "Saved transcription")).write(to: transcript)
        var original = record()
        original.source.finalizedAudioPath = audio.path
        let input = original, audit = Audit()
        if existing {
            try JSONEncoder().encode(QueueItem(id: input.id, transcribe: true, summary: true,
                actionItems: false, tags: false, autoQueued: true)).write(to: marker)
        }
        var actions = steps(input, audit: audit)
        if cancelCaller { actions.releaseResources = { withUnsafeCurrentTask { $0?.cancel() } } }
        let cleanup = actions
        try await Task { try await ProcessingPipeline().cancelWorkflow(steps: cleanup) }.value
        if existing {
            let item = try QueueItem.load(from: marker)
            #expect(!item.autoQueued && item.summary && !item.actionItems)
        } else {
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
        #expect(try JSONDecoder().decode(TranscriptionResult.self, from: Data(contentsOf: transcript)).text == "Saved transcription")
    }

    @Test @MainActor func suspendedReviewCheckpointSettlesBeforeCancellationReadsJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProcessingJobStore(rootURL: root)
        var original = record()
        original.source.finalizedAudioPath = nil
        let stale = original, audit = Audit()
        try await store.save(stale)
        let recording = Recording(fileURL: URL(fileURLWithPath: "/synthetic.wav"), duration: 3)
        let job = ProcessingJob(id: stale.id, recording: recording)
        job.task = Task { }
        await job.task?.value // held processing task has already returned
        let operation = RecordingManager.ReviewOperation(recording: recording, job: job)
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let reviewTask = Task { @MainActor in
            defer { operation.finish() }
            for await _ in gate { break }
            do {
                var durable = stale
                _ = durable.markCompleted(.speakerReviewCompleted, at: Date(timeIntervalSince1970: 200))
                try await store.save(durable)
                await audit.add("reviewFinished")
            } catch { Issue.record("Synthetic review failed: \(error)") }
        }
        var actions = steps(stale, audit: audit)
        actions.waitForJob = { @MainActor in
            await job.task?.value
            continuation.yield(())
            continuation.finish()
            await operation.waitForCompletion()
        }
        actions.snapshot = {
            #expect(await audit.calls.contains("reviewFinished"))
            return snapshot(stale)
        }
        actions.loadRecord = { try await store.load(id: $0) }
        actions.saveRecord = { try await store.save($0) }
        try await ProcessingPipeline().cancelWorkflow(steps: actions)
        await reviewTask.value
        operation.finish() // repeated completion is harmless
        await operation.waitForCompletion() // completion-before-wait is immediate
        let saved = try #require(try await store.load(id: stale.id))
        #expect(saved.status == .cancelled && saved.checkpoint.hasCompleted(.speakerReviewCompleted))
    }

    @Test(arguments: ["journal", "queue"])
    func unreadableRecoveryFilesKeepTheirOriginalBytes(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.m4a")
        try Data("audio".utf8).write(to: audio)
        var original = record()
        original.source.finalizedAudioPath = audio.path
        let input = original, audit = Audit()
        let jobs = root.appendingPathComponent("jobs")
        let store = ProcessingJobStore(rootURL: jobs)
        try await store.save(input)
        let poisoned = kind == "journal"
            ? jobs.appendingPathComponent(input.id.uuidString.lowercased()).appendingPathComponent("job.json")
            : root.appendingPathComponent("audio.queue.json")
        let bytes = Data("unreadable recovery fixture".utf8)
        try bytes.write(to: poisoned)
        var actions = steps(input, audit: audit)
        actions.loadRecord = { try await store.load(id: $0) }
        actions.saveRecord = { try await store.save($0) }
        try await ProcessingPipeline().cancelWorkflow(steps: actions)
        #expect(try Data(contentsOf: poisoned) == bytes)
        #expect(try Data(contentsOf: audio) == Data("audio".utf8))
        #expect(await audit.calls.contains(kind == "journal" ? "journalWarning" : "queueWarning"))
        if kind == "journal" {
            #expect(try QueueItem.load(from: root.appendingPathComponent("audio.queue.json")).autoQueued == false)
        }
    }
}
