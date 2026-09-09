import Foundation
import Testing
@testable import dBrief

@Suite("Saved library queries")
struct LibrarySmartQueryTests {
    private func fixture() throws -> (URL, URL, LibraryIndex) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (root, folder, LibraryIndex(cacheRoot: root.appendingPathComponent("cache"), jobsRoot: root.appendingPathComponent("jobs")))
    }

    @discardableResult private func recording(_ name: String, in folder: URL, date: Date, processed: Date? = nil,
                                              actions: [String] = [], completed: [String] = [], people: [String] = []) throws -> URL {
        let base = folder.appendingPathComponent(name)
        let audio = base.appendingPathExtension("wav")
        try Data([1]).write(to: audio)
        var metadata: [String: Any] = ["generatedTitle": name, "dateISO8601": ISO8601DateFormatter().string(from: date), "participants": people]
        if let processed {
            metadata["lastProcessingCompletion"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
                ProcessingCompletionStamp(jobID: UUID(), completedAt: processed)))
        }
        try JSONSerialization.data(withJSONObject: metadata).write(to: base.appendingPathExtension("json"))
        try JSONSerialization.data(withJSONObject: ["actionItems": actions, "completedActionItems": completed])
            .write(to: base.appendingPathExtension("insights.json"))
        return audio
    }

    @Test func actionPresetComposesTextAndStatusWithoutReadingCanonicalFiles() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try recording("Alpha launch", in: folder, date: .now, actions: ["Follow up"])
        try recording("Beta launch", in: folder, date: .now, actions: ["Follow up"], completed: ["Follow up"])
        try recording("Blank", in: folder, date: .now, actions: ["  "])
        _ = try await index.refresh(in: folder)
        enum UnexpectedRead: Error { case source }
        let reopened = LibraryIndex(cacheRoot: root.appendingPathComponent("cache"), jobsRoot: root.appendingPathComponent("jobs"), read: { _ in throw UnexpectedRead.source })
        let result = try await reopened.smartResults(in: folder, view: .unfinishedActions, text: "lau", status: .unprocessed)
        #expect(result.recordings.map(\.name) == ["Alpha launch"])
        #expect(result.work.isEmpty && result.people.isEmpty)
        #expect(try await reopened.smartResults(in: folder, view: .unfinishedActions, text: "Beta").recordings.isEmpty)
        #expect(try await reopened.smartResults(in: folder, view: .unfinishedActions, text: "* : \"").recordings.isEmpty)
        #expect(try await reopened.smartResults(in: folder, view: .all).recordings.count == 3)
    }

    @Test func recencyUsesCanonicalTimeWithInclusiveSevenDayCutoffAndNoFutureDates() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        try recording("newest-processing", in: folder, date: .distantPast, processed: now)
        try recording("cutoff", in: folder, date: now, processed: cutoff)
        try recording("too-old", in: folder, date: now, processed: cutoff.addingTimeInterval(-1))
        try recording("future", in: folder, date: now, processed: now.addingTimeInterval(1))
        try recording("unknown", in: folder, date: now)
        _ = try await index.refresh(in: folder)
        #expect(try await index.smartResults(in: folder, view: .recentlyProcessed, now: now).recordings.map(\.name) == ["newest-processing", "cutoff"])
        #expect(try await index.smartResults(in: folder, view: .recentlyProcessed, now: now.addingTimeInterval(1)).recordings.map(\.name) == ["future", "newest-processing"])
    }

    @Test(arguments: ["2026-03-29T12:00:00Z", "2026-12-31T23:30:00Z", "2026-10-25T12:00:00Z"])
    func peopleUseLocalCalendarMonthAndUniqueRecordingLinks(instant: String) async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try #require(ISO8601DateFormatter().date(from: instant))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
        let month = try #require(calendar.dateInterval(of: .month, for: now))
        try recording("start", in: folder, date: month.start, people: ["Alice", "ALICE", "Speaker 2", "Me"])
        try recording("end", in: folder, date: month.end.addingTimeInterval(-1), people: ["Alice", "Bob"])
        try recording("previous", in: folder, date: month.start.addingTimeInterval(-1), people: ["Alice"])
        try recording("next", in: folder, date: month.end, people: ["Alice"])
        _ = try await index.refresh(in: folder)
        let result = try await index.smartResults(in: folder, view: .peopleThisMonth, now: now, calendar: calendar)
        #expect(result.people.map(\.person.key) == ["alice", "bob"])
        #expect(result.people.first?.recordings.map(\.name) == ["end", "start"])
        #expect(result.people.last?.recordings.map(\.name) == ["end"])
        #expect(result.recordings.isEmpty && result.work.isEmpty)
        let searched = try await index.smartResults(in: folder, view: .peopleThisMonth, text: "start", now: now, calendar: calendar)
        #expect(searched.people.map(\.person.key) == ["alice"])
        #expect(searched.people.first?.recordings.map(\.name) == ["start"])
    }

    @Test func workPresetsRetainUnfinalizedFailuresAndExcludeActiveIDsAndAudio() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try recording("launch-audio", in: folder, date: .now)
        try Data(#"{"text":"budget"}"#.utf8).write(to: audio.deletingPathExtension().appendingPathExtension("transcript.json"))
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        var ids: [UUID] = []
        for (title, status, path) in [("Retry interview", PersistedProcessingJob.Status.failed, Optional<String>.none),
                                      ("Await work", .running, audio.path)] {
            let id = UUID(); ids.append(id)
            try await jobs.save(PersistedProcessingJob(id: id, recordingID: UUID(), createdAt: .now, updatedAt: .now,
                status: status, request: .init(transcribe: true, summary: false, actionItems: false, tags: false, titleWasUserProvided: false, autoResume: false),
                source: .init(recordingDate: .now, duration: 1, fileSize: 1, meetingTitle: title, associatedApp: nil,
                    participants: [], calendarEvent: nil, echoSuppressionApplied: false, recoveryManifestPath: nil,
                    stagedInputPath: nil, finalizedAudioPath: path, segmentAudioPaths: [], metadataPath: nil)))
        }
        _ = try await index.refresh(in: folder)
        #expect(try await index.smartResults(in: folder, view: .failedJobs).work.map(\.title) == ["Retry interview"])
        #expect(try await index.smartResults(in: folder, view: .queuedInterrupted).work.count == 2)
        #expect(try await index.smartResults(in: folder, view: .queuedInterrupted, text: "launch").work.map(\.title) == ["Await work"])
        #expect(try await index.smartResults(in: folder, view: .queuedInterrupted, text: "ret").work.map(\.title) == ["Retry interview"])
        #expect(try await index.smartResults(in: folder, view: .queuedInterrupted, text: "interrupted budget").work.map(\.title) == ["Await work"])
        let active = try await index.smartResults(in: folder, view: .queuedInterrupted, excludingWorkIDs: [ids[0]], excludingAudioURLs: [audio])
        #expect(active.work.isEmpty)
    }

    @Test @MainActor func selectedPresetSurvivesReopeningAndUnknownValuesUseAllRecordings() throws {
        let suite = "dBrief-smart-query-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = LibrarySmartViewSelection(defaults: defaults)
        #expect(selection.load() == .all)
        selection.save(.peopleThisMonth)
        #expect(LibrarySmartViewSelection(defaults: defaults).load() == .peopleThisMonth)
        defaults.set("future-preset", forKey: LibrarySmartViewSelection.key)
        #expect(selection.load() == .all)
    }

    @Test func unavailableCacheThrowsInsteadOfReturningAnEmptySuccessfulView() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) { try await index.smartResults(in: folder, view: .failedJobs) }
    }

    @Test func alreadyCancelledQueryCannotPublishResults() async throws {
        let (root, folder, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await index.refresh(in: folder)
        let query = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await index.smartResults(in: folder, view: .all)
        }
        await #expect(throws: CancellationError.self) { try await query.value }
    }
}
