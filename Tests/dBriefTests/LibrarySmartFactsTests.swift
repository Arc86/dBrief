import Foundation
import Testing
@testable import dBrief

@Suite("Library smart-view facts")
struct LibrarySmartFactsTests {
    private func fixture() throws -> (URL, URL, LibraryIndex) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (root, folder, LibraryIndex(cacheRoot: root.appendingPathComponent("cache"),
            jobsRoot: root.appendingPathComponent("jobs")))
    }

    private func job(status: PersistedProcessingJob.Status = .failed, audio: URL? = nil) -> PersistedProcessingJob {
        PersistedProcessingJob(id: UUID(), recordingID: UUID(), createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000), status: status,
            request: .init(transcribe: true, summary: false, actionItems: false, tags: false,
                titleWasUserProvided: false, autoResume: false),
            source: .init(recordingDate: .now, duration: 1, fileSize: 1, meetingTitle: "Staged interview",
                associatedApp: "Zoom", participants: [], calendarEvent: nil, echoSuppressionApplied: false,
                recoveryManifestPath: nil, stagedInputPath: "/unavailable/input.wav", finalizedAudioPath: audio?.path,
                segmentAudioPaths: [], metadataPath: nil), failureStage: .finalization)
    }

    @Test func failedUnfinalizedWorkSurvivesWithoutRecordingRows() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        var failed = job()
        try await store.save(failed)
        _ = try await index.refresh(in: folder)
        #expect(try await index.search(in: folder).isEmpty)
        let db = try LibraryDatabase(url: index.databaseURL(for: folder), readOnly: true)
        let rows = try db.rows("SELECT title, audioPath, failed FROM work")
        #expect(rows == [["Staged interview", "", "1"]])
        #expect(try await index.refresh(in: folder).sourceReads == 0)
        failed.dismissedFromQueue = true
        try await store.save(failed)
        _ = try await index.refresh(in: folder)
        #expect(try db.rows("SELECT id FROM work").isEmpty)
    }

    @Test func indexesActionCompletionPeopleAndCanonicalDate() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = folder.appendingPathComponent("meeting")
        try Data([1]).write(to: base.appendingPathExtension("wav"))
        let stamp = ProcessingCompletionStamp(jobID: UUID(), completedAt: Date(timeIntervalSince1970: 9_000))
        let stampObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stamp))
        let metadata: [String: Any] = ["participants": ["den Boer, Bart", "Alice", "Me"],
            "calendarAttendees": ["BART DEN BOER", "Jesper"], "lastProcessingCompletion": stampObject]
        try JSONSerialization.data(withJSONObject: metadata).write(to: base.appendingPathExtension("json"))
        let insights: [String: Any] = ["actionItems": ["Done", "Open", "Open", "  "],
            "completedActionItems": ["Done", "Removed"]]
        try JSONSerialization.data(withJSONObject: insights).write(to: base.appendingPathExtension("insights.json"))
        let rich = RichTranscript(segments: [], speakerLabels: [
            .init(id: "0", displayName: "Jesper"), .init(id: "1", displayName: "Speaker 2"),
            .init(id: "2", displayName: "Caroline"), .init(id: "3", displayName: "Unknown")], meSpeakerId: "0")
        try JSONEncoder().encode(rich).write(to: base.appendingPathExtension("richtranscript.json"))
        _ = try await index.refresh(in: folder)
        let db = try LibraryDatabase(url: index.databaseURL(for: folder), readOnly: true)
        #expect(try db.rows("SELECT unfinishedActions, processedAt FROM documents") == [["2", "9000.0"]])
        #expect(try db.rows("SELECT name FROM people ORDER BY key").map { $0[0] } == ["Alice", "Bart den Boer", "Caroline"])
        #expect(try await index.refresh(in: folder).sourceReads == 0)
    }

    private func batch(id: UUID = UUID(), audio: URL, status: IntegrationDeliveryBatch.Delivery.Status) -> IntegrationDeliveryBatch {
        IntegrationDeliveryBatch(id: id, recordingID: UUID(), createdAt: .now,
            bundle: .init(title: "Delivery review", createdAt: .now, durationSeconds: 1, audioFileURL: audio,
                transcript: "Private text must not enter work cache", summary: "", actionItems: [], tags: [],
                sentiment: nil, markdown: "Private export", calendarEvent: nil),
            deliveries: [.init(id: UUID(), destination: .webhook, configurationDigest: "config", status: status)])
    }

    @Test func olderFailedDeliveryIsNotHiddenByNewerSuccessAndSharesRecoveryDeduplication() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = folder.appendingPathComponent("missing.wav")
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        let deliveries = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("Integration Deliveries"))
        let oldJob = job(audio: audio)
        try await jobs.save(oldJob)
        let failed = batch(id: oldJob.id, audio: audio, status: .uncertain)
        try await deliveries.save(failed)
        var newJob = job(status: .completed, audio: audio)
        newJob.updatedAt = .now
        try await jobs.save(newJob)
        let success = batch(id: newJob.id, audio: audio, status: .succeeded)
        try await deliveries.save(success)
        _ = try await index.refresh(in: folder)
        let db = try LibraryDatabase(url: index.databaseURL(for: folder), readOnly: true)
        #expect(try db.rows("SELECT title, failed FROM work") == [["Delivery review", "1"]])
        #expect(try db.rows("SELECT payload FROM work_sources").allSatisfy { !$0[0].contains("Private") })
        let expected = RecoveryQueueEntry.entries(jobs: [oldJob, newJob], deliveries: [failed, success], queuedIDs: [], activeID: nil)
        let actual = try db.rows("SELECT payload FROM work").map { try JSONDecoder().decode(LibraryWorkItem.self, from: Data($0[0].utf8)) }
        #expect(actual.map(\.recoveryID) == expected.map(\.id))
        #expect(actual.first?.target == .delivery)
        #expect(try await index.refresh(in: folder).sourceReads == 0)
        var dismissed = oldJob
        dismissed.dismissedFromQueue = true
        try await jobs.save(dismissed)
        _ = try await index.refresh(in: folder)
        #expect(try db.rows("SELECT id FROM work").isEmpty)
    }

    @Test func captureQueueAndMissingInputRemainVisibleAndDeduplicateOwningJob() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let session = try InterruptedSessionStore.createSession(id: id, startedAt: .now,
            rootURL: root.appendingPathComponent("Recording Recovery"))
        try Data([1]).write(to: session.directoryURL.appendingPathComponent("capture.mic.caf"))
        let base = folder.appendingPathComponent("queued")
        try Data([1]).write(to: base.appendingPathExtension("wav"))
        let queuedJob = job(status: .queued, audio: base.appendingPathExtension("wav"))
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        try await jobs.save(queuedJob)
        try JSONEncoder().encode(QueueItem(id: queuedJob.id, transcribe: true, summary: false, actionItems: false, tags: false))
            .write(to: base.appendingPathExtension("queue.json"))
        // Legacy marker with no audio still has stable identity, including after rebuild.
        let orphan = folder.appendingPathComponent("orphan.queue.json")
        try Data(#"{"transcribe":true,"summary":false,"actionItems":false,"tags":false}"#.utf8).write(to: orphan)
        _ = try await index.refresh(in: folder)
        let db = try LibraryDatabase(url: index.databaseURL(for: folder), readOnly: true)
        let first = try db.rows("SELECT id, payload FROM work ORDER BY id")
        #expect(first.count == 3)
        #expect(try db.rows("SELECT title FROM work WHERE failed = 1") == [["orphan"]])
        #expect(try await index.refresh(in: folder).sourceReads == 0)
        _ = try await index.refresh(in: folder, rebuild: true)
        #expect(try db.rows("SELECT id, payload FROM work ORDER BY id") == first)
        var owner = job()
        owner.source.recoveryManifestPath = session.manifestURL.path
        owner.failureStage = .missingInput
        try await jobs.save(owner)
        _ = try await index.refresh(in: folder)
        #expect(try db.rows("SELECT id FROM work WHERE id LIKE 'capture:%'").isEmpty)
        #expect(try db.rows("SELECT payload FROM work WHERE id LIKE 'recovery:%'").first?.first?.contains("Recording unavailable") == true)
        // Removing a track changes availability even when session.json is unchanged.
        try await jobs.remove(id: owner.id)
        try FileManager.default.removeItem(at: session.directoryURL.appendingPathComponent("capture.mic.caf"))
        _ = try await index.refresh(in: folder)
        #expect(try db.rows("SELECT failed FROM work WHERE id LIKE 'capture:%'") == [["1"]])
        _ = try InterruptedSessionStore.updateState(at: session.manifestURL, to: .completed)
        _ = try await index.refresh(in: folder)
        #expect(try db.rows("SELECT id FROM work WHERE id LIKE 'capture:%'").isEmpty)
    }

    @Test func corruptRecoverySourceRollsBackTheEntireSnapshot() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        let saved = job()
        try await jobs.save(saved)
        let audio = folder.appendingPathComponent("before.wav")
        try Data([1]).write(to: audio)
        _ = try await index.refresh(in: folder)
        let db = try LibraryDatabase(url: index.databaseURL(for: folder), readOnly: true)
        let before = try db.rows("SELECT payload FROM work")
        try FileManager.default.moveItem(at: audio, to: folder.appendingPathComponent("after.wav"))
        let manifest = root.appendingPathComponent("jobs").appendingPathComponent(saved.id.uuidString.lowercased()).appendingPathComponent("job.json")
        try Data("corrupt".utf8).write(to: manifest)
        await #expect(throws: LibraryIndex.Failure.self) { try await index.refresh(in: folder) }
        #expect(try db.rows("SELECT payload FROM work") == before)
        #expect(try await index.search(in: folder).map(\.name) == ["before"])
        try await jobs.save(saved)
        _ = try await index.refresh(in: folder)
        #expect(try await index.search(in: folder).map(\.name) == ["after"])
    }

    @Test func queuedMarkerKeepsTheFailureOfItsProcessingAttempt() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = folder.appendingPathComponent("queued-failure.wav")
        try Data([1]).write(to: audio)
        var failed = job(audio: audio)
        failed.failureStage = .transcription
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        try await jobs.save(failed)
        try JSONEncoder().encode(QueueItem(id: failed.id, transcribe: true, summary: false, actionItems: false, tags: false))
            .write(to: audio.deletingPathExtension().appendingPathExtension("queue.json"))
        _ = try await index.refresh(in: folder)
        let db = try LibraryDatabase(url: index.databaseURL(for: folder), readOnly: true)
        #expect(try db.rows("SELECT failed FROM work") == [["1"]])
        let payload = try #require(db.rows("SELECT payload FROM work").first?.first)
        let item = try JSONDecoder().decode(LibraryWorkItem.self, from: Data(payload.utf8))
        #expect(item.status == "Transcription failed")
        #expect(item.recoveryID == failed.id)
    }

    @Test func pendingDeliveryDoesNotHideFailureToSaveItsFirstAttempt() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = folder.appendingPathComponent("delivery.wav")
        var failed = job(audio: audio)
        failed.failureStage = .integrations
        try await ProcessingJobStore(rootURL: root.appendingPathComponent("jobs")).save(failed)
        try await IntegrationDeliveryStore(rootURL: root.appendingPathComponent("Integration Deliveries"))
            .save(batch(id: failed.id, audio: audio, status: .pending))
        _ = try await index.refresh(in: folder)
        let db = try LibraryDatabase(url: index.databaseURL(for: folder), readOnly: true)
        #expect(try db.rows("SELECT failed FROM work") == [["1"]])
    }

    @Test func editsReplaceIndexedActionsAndPeopleWithoutInventingProcessingDate() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = folder.appendingPathComponent("edited")
        try Data([1]).write(to: base.appendingPathExtension("wav"))
        try Data(#"{"participants":["Alice"]}"#.utf8).write(to: base.appendingPathExtension("json"))
        try Data(#"{"actionItems":["Follow up"]}"#.utf8).write(to: base.appendingPathExtension("insights.json"))
        _ = try await index.refresh(in: folder)
        let db = try LibraryDatabase(url: index.databaseURL(for: folder), readOnly: true)
        #expect(try db.rows("SELECT unfinishedActions, processedAt IS NULL FROM documents") == [["1", "1"]])
        try Data(#"{"participants":["Bob"]}"#.utf8).write(to: base.appendingPathExtension("json"), options: .atomic)
        try Data(#"{"actionItems":["Follow up"],"completedActionItems":["Follow up"]}"#.utf8)
            .write(to: base.appendingPathExtension("insights.json"), options: .atomic)
        _ = try await index.refresh(in: folder)
        #expect(try db.rows("SELECT unfinishedActions, processedAt IS NULL FROM documents") == [["0", "1"]])
        #expect(try db.rows("SELECT name FROM people") == [["Bob"]])
        #expect(try await index.search(in: folder, text: "Alice").isEmpty)
        try FileManager.default.removeItem(at: base.appendingPathExtension("wav"))
        _ = try await index.refresh(in: folder)
        #expect(try db.rows("SELECT name FROM people").isEmpty)
    }

    @Test func schemaRebuildKeepsCommittedWorkVisibleAndRollsBackAllNewFacts() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        var saved = job(status: .running)
        try await jobs.save(saved)
        _ = try await index.refresh(in: folder)
        let databaseURL = index.databaseURL(for: folder)
        let db = try LibraryDatabase(url: databaseURL)
        try db.rows("PRAGMA user_version=99")
        saved.status = .failed
        try await jobs.save(saved)
        enum Stop: Error { case beforeCommit }
        let failing = LibraryIndex(cacheRoot: root.appendingPathComponent("cache"), jobsRoot: root.appendingPathComponent("jobs"),
            beforeCommit: {
                let reader = try LibraryDatabase(url: databaseURL, readOnly: true)
                #expect(try reader.rows("SELECT failed FROM work") == [["0"]])
                throw Stop.beforeCommit
            })
        await #expect(throws: Stop.self) { try await failing.refresh(in: folder) }
        #expect(try db.rows("SELECT failed FROM work") == [["0"]])
        #expect(try db.rows("PRAGMA user_version") == [["99"]])
        _ = try await index.refresh(in: folder)
        #expect(try db.rows("SELECT failed FROM work") == [["1"]])
        #expect(try db.rows("PRAGMA user_version") == [["3"]])
    }

    @Test func remembersQueuedWorkInAnotherProfileFolderAndKeepsItWhenOffline() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("old-profile")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let audio = other.appendingPathComponent("deferred.wav")
        try Data([1]).write(to: audio)
        let queue = QueueItem(transcribe: true, summary: false, actionItems: false, tags: false)
        try JSONEncoder().encode(queue).write(to: audio.deletingPathExtension().appendingPathExtension("queue.json"))
        var schedule = QueueSchedule()
        schedule.rememberFolder(other)
        try await QueueScheduleStore(url: root.appendingPathComponent("Queue/schedule.json")).save(schedule)
        _ = try await index.refresh(in: folder)
        let db = try LibraryDatabase(url: index.databaseURL(for: folder), readOnly: true)
        let rows = try db.rows("SELECT payload FROM work")
        #expect(rows.count == 1)
        if let payload = rows.first?.first {
            let work = try JSONDecoder().decode(LibraryWorkItem.self, from: Data(payload.utf8))
            #expect(work.recoveryID == queue.id)
            #expect(work.audioURL?.standardizedFileURL == audio.standardizedFileURL)
            #expect(!work.failed)
        }
        #expect(try await index.search(in: folder).isEmpty)
        #expect(try await index.refresh(in: folder).sourceReads == 0)
        try FileManager.default.moveItem(at: other, to: root.appendingPathComponent("offline"))
        await #expect(throws: (any Error).self) { try await index.refresh(in: folder) }
        #expect(try db.rows("SELECT payload FROM work") == rows)
    }

    @Test(arguments: ["delivery-corrupt", "delivery-future", "capture-corrupt", "capture-future", "capture-escape", "queue-corrupt", "queue-future", "queue-bool", "schedule-future"])
    func unreadableWorkSourcesNeverPublishAnEmptyReplacement(kind: String) async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = job()
        try await ProcessingJobStore(rootURL: root.appendingPathComponent("jobs")).save(saved)
        _ = try await index.refresh(in: folder)
        let db = try LibraryDatabase(url: index.databaseURL(for: folder), readOnly: true)
        let before = try db.rows("SELECT payload FROM work")
        let id = UUID()
        let target: URL
        let data: Data
        if kind.hasPrefix("delivery") {
            target = root.appendingPathComponent("Integration Deliveries/\(id.uuidString.lowercased()).json")
            var value = batch(id: id, audio: folder.appendingPathComponent("missing.wav"), status: .pending)
            value.version = 99
            data = kind.hasSuffix("corrupt") ? Data("corrupt".utf8) : try JSONEncoder().encode(value)
        } else if kind.hasPrefix("capture") {
            target = root.appendingPathComponent("Recording Recovery/\(id.uuidString.lowercased())/session.json")
            let manifest = InterruptedSessionManifest(version: kind.hasSuffix("future") ? 99 : 1, id: id,
                startedAt: .now, state: .capturing, tracks: [.init(kind: .microphone, relativePath: "../outside.caf")])
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            data = kind.hasSuffix("corrupt") ? Data("corrupt".utf8) : try encoder.encode(manifest)
        } else if kind.hasPrefix("queue") {
            target = folder.appendingPathComponent("future.queue.json")
            data = Data((kind.hasSuffix("corrupt") ? "corrupt" : #"{"version":99,"transcribe":true,"summary":false,"actionItems":false,"tags":false}"#).utf8)
        } else {
            target = root.appendingPathComponent("Queue/schedule.json")
            data = Data(#"{"version":99,"paused":false,"order":[]}"#.utf8)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let written = kind == "queue-bool" ? Data(#"{"version":true,"transcribe":true,"summary":false,"actionItems":false,"tags":false}"#.utf8) : data
        try written.write(to: target)
        await #expect(throws: (any Error).self) { try await index.refresh(in: folder) }
        #expect(try db.rows("SELECT payload FROM work") == before)
        #expect(try Data(contentsOf: target) == written)
    }

    @Test @MainActor func modelIncludesConfiguredFoldersBeforeTheyHaveScheduleHistory() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("configured")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let marker = other.appendingPathComponent("legacy.queue.json")
        try Data(#"{"transcribe":true,"summary":false,"actionItems":false,"tags":false}"#.utf8).write(to: marker)
        let model = RecordingLibraryModel(index: index)
        model.open(folder, configuredQueueFolders: [other, other])
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.refreshedRevision == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.refreshedRevision > 0)
        #expect(model.error == nil)
        let db = try LibraryDatabase(url: index.databaseURL(for: folder), readOnly: true)
        #expect(try db.rows("SELECT title FROM work") == [["legacy"]])
        #expect(try await index.refresh(in: folder, configuredQueueFolders: [other]).sourceReads == 0)
    }

    @Test func unusedConfiguredDestinationDoesNotBlockButPreviouslyIndexedWorkDoes() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("not-created/meetings")
        try Data([1]).write(to: folder.appendingPathComponent("visible.wav"))
        _ = try await index.refresh(in: folder, configuredQueueFolders: [destination])
        #expect(try await index.search(in: folder).map(\.name) == ["visible"])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(#"{"transcribe":true,"summary":false,"actionItems":false,"tags":false}"#.utf8)
            .write(to: destination.appendingPathComponent("waiting.queue.json"))
        _ = try await index.refresh(in: folder, configuredQueueFolders: [destination])
        let db = try LibraryDatabase(url: index.databaseURL(for: folder), readOnly: true)
        let rows = try db.rows("SELECT payload FROM work")
        #expect(rows.count == 1)
        try FileManager.default.moveItem(at: destination, to: root.appendingPathComponent("unavailable"))
        await #expect(throws: (any Error).self) { try await index.refresh(in: folder, configuredQueueFolders: [destination]) }
        #expect(try db.rows("SELECT payload FROM work") == rows)
    }

    @Test func oldSchemaCannotReuseFactsThatBypassedNewSourceValidation() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = folder.appendingPathComponent("old-schema.queue.json")
        try Data(#"{"transcribe":true,"summary":false,"actionItems":false,"tags":false}"#.utf8).write(to: marker)
        _ = try await index.refresh(in: folder)
        let db = try LibraryDatabase(url: index.databaseURL(for: folder))
        let before = try db.rows("SELECT payload FROM work")
        try Data(#"{"version":99,"transcribe":true,"summary":false,"actionItems":false,"tags":false}"#.utf8).write(to: marker)
        // Schema 2's older validator could cache this as an ordinary queue ID.
        try db.rows("UPDATE work_sources SET fingerprint = ? WHERE path = ?", [try index.fileFingerprint(marker), marker.standardizedFileURL.path])
        try db.rows("PRAGMA user_version=2")
        await #expect(throws: (any Error).self) { try await index.refresh(in: folder) }
        #expect(try db.rows("SELECT payload FROM work") == before)
    }
}
