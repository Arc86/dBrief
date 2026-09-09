import Foundation
import Testing
@testable import dBrief

struct LibraryIndexTests {
    private func fixture() throws -> (URL, URL, LibraryIndex) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (root, folder, LibraryIndex(cacheRoot: root.appendingPathComponent("cache"), jobsRoot: root.appendingPathComponent("jobs")))
    }

    private func write(_ object: [String: Any], base: URL, ext: String) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: base.appendingPathExtension(ext), options: .atomic)
    }

    @Test func searchesEveryFieldAndPrefersEditedTranscript() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = folder.appendingPathComponent("2026-09-08_1234_sync.wav")
        try Data([1]).write(to: audio)
        let base = audio.deletingPathExtension()
        try write(["generatedTitle": "Budget café", "durationSeconds": 34,
                   "participants": ["Alice"], "calendarAttendees": ["Bob"],
                   "dateISO8601": "2026-09-08T12:34:00Z", "associatedApp": "Teams"], base: base, ext: "json")
        try write(["text": "obsoleteword"], base: base, ext: "transcript.json")
        let rich = RichTranscript(segments: [.init(start: 0, end: 1, text: "Launch zeppelin", originalText: "obsoleteword")],
                                  speakerLabels: [.init(id: "0", displayName: "Caroline")])
        try JSONEncoder().encode(rich).write(to: base.appendingPathExtension("richtranscript.json"))
        try write(["tags": ["priority"], "actionItems": ["David: approve purchase"]], base: base, ext: "insights.json")
        let first = try await index.refresh(in: folder)
        #expect(first.indexedRecordings == 1)
        for query in ["budget", "cafe", "Alice", "Bob", "Caroline", "priority", "David", "2026-09-08", "Teams", "zepp"] {
            #expect(try await index.search(in: folder, text: query).count == 1, "Missing field: \(query)")
        }
        #expect(try await index.search(in: folder, text: "obsoleteword").isEmpty)
        #expect(try await index.search(in: folder, text: "\" OR * :").isEmpty)
        let warm = try await index.refresh(in: folder)
        #expect(warm.sourceReads == 0)
        #expect(warm.indexedRecordings == 0)
        enum UnexpectedRead: Error { case sidecar }
        let reopened = LibraryIndex(cacheRoot: root.appendingPathComponent("cache"), jobsRoot: root.appendingPathComponent("jobs"),
            read: { _ in throw UnexpectedRead.sidecar })
        #expect(try await reopened.search(in: folder, text: "zeppelin").count == 1)
        #expect(try await reopened.refresh(in: folder).sourceReads == 0)
    }

    @Test func editsDeletesAndCacheRecreationPreserveSources() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = folder.appendingPathComponent("meeting.wav")
        try Data([1, 2]).write(to: audio)
        let base = audio.deletingPathExtension()
        try write(["generatedTitle": "Before"], base: base, ext: "json")
        _ = try await index.refresh(in: folder)
        try write(["generatedTitle": "After"], base: base, ext: "json")
        _ = try await index.refresh(in: folder)
        #expect(try await index.search(in: folder, text: "Before").isEmpty)
        #expect(try await index.search(in: folder, text: "After").count == 1)
        try FileManager.default.removeItem(at: index.databaseURL(for: folder))
        _ = try await index.refresh(in: folder)
        #expect(try await index.search(in: folder, text: "After").count == 1)
        #expect(try Data(contentsOf: audio) == Data([1, 2]))
        try FileManager.default.removeItem(at: audio)
        _ = try await index.refresh(in: folder)
        #expect(try await index.search(in: folder).isEmpty)
        #expect(FileManager.default.fileExists(atPath: base.appendingPathExtension("json").path))
    }

    @Test func legacyQueueAndMalformedSidecarsHaveUsefulStatuses() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["queued", "raw", "broken", "done"] {
            try Data([1]).write(to: folder.appendingPathComponent(name + ".wav"))
        }
        try write(["transcribe": true, "summary": false, "actionItems": false, "tags": false], base: folder.appendingPathComponent("queued"), ext: "queue.json")
        try Data("invalid".utf8).write(to: folder.appendingPathComponent("broken.transcript.json"))
        try write(["text": "Complete"], base: folder.appendingPathComponent("done"), ext: "transcript.json")
        _ = try await index.refresh(in: folder)
        for (status, name) in [(LibraryRecordingStatus.queued, "queued"), (.unprocessed, "raw"), (.incomplete, "broken"), (.done, "done")] {
            #expect(try await index.search(in: folder, status: status).map(\.name) == [name])
        }
    }

    @Test func unavailableFolderDoesNotErasePreviousSnapshot() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: folder.appendingPathComponent("saved.wav"))
        _ = try await index.refresh(in: folder)
        let moved = root.appendingPathComponent("temporarily-offline")
        try FileManager.default.moveItem(at: folder, to: moved)
        await #expect(throws: (any Error).self) { try await index.refresh(in: folder) }
        #expect(try await index.search(in: folder).map(\.name) == ["saved"])
    }

    @Test func corruptCacheRebuildsWithoutChangingCanonicalFiles() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = folder.appendingPathComponent("survivor.wav")
        try Data([7]).write(to: audio)
        _ = try await index.refresh(in: folder)
        try Data("corrupt database".utf8).write(to: index.databaseURL(for: folder))
        _ = try await index.refresh(in: folder, rebuild: true)
        #expect(try await index.search(in: folder).map(\.name) == ["survivor"])
        #expect(try Data(contentsOf: audio) == Data([7]))
    }

    @Test func durableJobsUpdateFiltersAndSourceWithoutRereadingUnchangedManifests() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = folder.appendingPathComponent("job.wav")
        try Data([1]).write(to: audio)
        let store = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        var job = PersistedProcessingJob(id: UUID(), recordingID: UUID(), createdAt: .now, updatedAt: .now, status: .queued,
            request: .init(transcribe: true, summary: false, actionItems: false, tags: false, titleWasUserProvided: false, autoResume: false),
            source: .init(recordingDate: .now, duration: 1, fileSize: 1, meetingTitle: "Queue", associatedApp: "Zoom",
                participants: [], calendarEvent: nil, echoSuppressionApplied: false,
                recoveryManifestPath: nil, stagedInputPath: nil, finalizedAudioPath: audio.path, segmentAudioPaths: [], metadataPath: nil))
        for (jobStatus, filter) in [(PersistedProcessingJob.Status.queued, LibraryRecordingStatus.queued),
                                   (.failed, .failed), (.running, .incomplete), (.cancelled, .incomplete), (.completed, .done)] {
            job.status = jobStatus
            job.updatedAt = job.updatedAt.addingTimeInterval(1)
            try await store.save(job)
            _ = try await index.refresh(in: folder)
            #expect(try await index.search(in: folder, text: "Zoom", status: filter).count == 1)
            #expect(try await index.refresh(in: folder).sourceReads == 0)
        }
        job.status = .failed
        job.dismissedFromQueue = true
        try await store.save(job)
        _ = try await index.refresh(in: folder)
        #expect(try await index.search(in: folder, status: .failed).isEmpty)
        #expect(try await index.search(in: folder, status: .unprocessed).count == 1)
        try await store.remove(id: job.id)
        _ = try await index.refresh(in: folder)
        #expect(try await index.search(in: folder, text: "Zoom").isEmpty)
    }

    @Test(arguments: [false, true])
    func readersSeeCompleteSnapshotDuringRebuildAndFailureRollsBack(schemaUpgrade: Bool) async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = folder.appendingPathComponent("atomic.wav")
        try Data([1]).write(to: audio)
        let base = audio.deletingPathExtension()
        try write(["generatedTitle": "Original"], base: base, ext: "json")
        _ = try await index.refresh(in: folder)
        if schemaUpgrade {
            let db = try LibraryDatabase(url: index.databaseURL(for: folder))
            try db.rows("PRAGMA user_version=99")
        }
        try write(["generatedTitle": "Replacement"], base: base, ext: "json")
        let gate = IndexCommitGate()
        let rebuilding = LibraryIndex(cacheRoot: root.appendingPathComponent("cache"), jobsRoot: root.appendingPathComponent("jobs"),
            beforeCommit: { gate.entered.signal(); _ = gate.resume.wait(timeout: .now() + 10) })
        let refresh = Task { try await rebuilding.refresh(in: folder, rebuild: true) }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: gate.entered.wait(timeout: .now() + 10) == .success)
            }
        }
        #expect(started)
        let during = try await index.search(in: folder, text: "Original")
        #expect(during.count == 1)
        #expect(try await index.search(in: folder, text: "Replacement").isEmpty)
        gate.resume.signal()
        _ = try await refresh.value
        #expect(try await index.search(in: folder, text: "Original").isEmpty)
        #expect(try await index.search(in: folder, text: "Replacement").count == 1)

        enum InjectedFailure: Error { case stop }
        if schemaUpgrade {
            let db = try LibraryDatabase(url: index.databaseURL(for: folder))
            try db.rows("PRAGMA user_version=99")
        }
        let failing = LibraryIndex(cacheRoot: root.appendingPathComponent("cache"), jobsRoot: root.appendingPathComponent("jobs"),
            beforeCommit: { throw InjectedFailure.stop })
        try write(["generatedTitle": "Uncommitted"], base: base, ext: "json")
        await #expect(throws: InjectedFailure.self) { try await failing.refresh(in: folder, rebuild: true) }
        #expect(try await index.search(in: folder, text: "Replacement").count == 1)
        #expect(try await index.search(in: folder, text: "Uncommitted").isEmpty)
    }

    @Test func largeWarmLibraryDoesNotDecodeSidecarsAndSingleEditIsIncremental() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for number in 0..<1_000 {
            let base = folder.appendingPathComponent("meeting-\(number)")
            try Data([1]).write(to: base.appendingPathExtension("wav"))
            try write(["text": "Discuss topic\(number)"], base: base, ext: "transcript.json")
        }
        let cold = try await index.refresh(in: folder)
        #expect(cold.indexedRecordings == 1_000)
        let warm = try await index.refresh(in: folder)
        #expect(warm.sourceReads == 0)
        #expect(warm.indexedRecordings == 0)
        #expect(try await index.search(in: folder, text: "topic999").count == 1)
        let base = folder.appendingPathComponent("meeting-500")
        try write(["text": "replacementunique"], base: base, ext: "transcript.json")
        let changed = try await index.refresh(in: folder)
        #expect(changed.sourceReads == 1)
        #expect(changed.indexedRecordings == 1)
        #expect(try await index.search(in: folder, text: "replacementunique").count == 1)
        #expect(try await index.search(in: folder, text: "topic500").isEmpty)
        #expect(try await index.search(in: folder, limit: 20).count == 20)
    }

    @Test func schemaVersionRecreatesOnlyCacheAndFoldersStayIsolated() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("first.wav"))
        try Data([2]).write(to: other.appendingPathComponent("second.wav"))
        _ = try await index.refresh(in: folder)
        _ = try await index.refresh(in: other)
        do {
            let db = try LibraryDatabase(url: index.databaseURL(for: folder))
            try db.rows("PRAGMA user_version=99")
        }
        _ = try await index.refresh(in: folder)
        #expect(try await index.search(in: folder).map(\.name) == ["first"])
        #expect(try await index.search(in: other).map(\.name) == ["second"])
    }

    @Test @MainActor
    func warmModelDoesNotValidateSelectionBeforeDiscoveryAndLatestQueryWins() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: folder.appendingPathComponent("old.wav"))
        _ = try await index.refresh(in: folder)
        let newlySelected = folder.appendingPathComponent("new.wav")
        try Data([2]).write(to: newlySelected)
        let gate = IndexCommitGate()
        let delayed = LibraryIndex(cacheRoot: root.appendingPathComponent("cache"), jobsRoot: root.appendingPathComponent("jobs"),
            beforeCommit: { gate.entered.signal(); _ = gate.resume.wait(timeout: .now() + 10) })
        let model = RecordingLibraryModel(index: delayed)
        model.open(folder)
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: gate.entered.wait(timeout: .now() + 10) == .success)
            }
        }
        #expect(started)
        #expect(model.items.map(\.name) == ["old"])
        #expect(model.refreshedRevision == 0)
        gate.resume.signal()
        try await waitUntil { model.refreshedRevision > 0 }
        #expect(model.items.contains { $0.url == newlySelected })
        model.search(text: "old", status: nil)
        model.search(text: "new", status: .unprocessed)
        try await waitUntil { model.matches.map(\.name) == ["new"] }
        #expect(model.items.count == 2)
        #expect(model.error == nil)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

private final class IndexCommitGate: Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
}
