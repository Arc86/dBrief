import Foundation
import Testing
@testable import dBrief

@Suite("Processing job persistence")
struct ProcessingJobStoreTests {
    private func makeJob(
        id: UUID = UUID(),
        recordingID: UUID = UUID(),
        version: Int = PersistedProcessingJob.currentVersion,
        checkpoint: ProcessingCheckpoint? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 100)
    ) -> PersistedProcessingJob {
        PersistedProcessingJob(
            version: version,
            id: id,
            recordingID: recordingID,
            createdAt: createdAt,
            updatedAt: createdAt,
            status: .running,
            request: .init(
                transcribe: true,
                summary: true,
                actionItems: false,
                tags: true,
                titleWasUserProvided: false,
                autoResume: true
            ),
            source: .init(
                recordingDate: createdAt,
                duration: 42,
                fileSize: 123,
                meetingTitle: "Durable meeting",
                associatedApp: "Tests",
                participants: ["Ada"],
                calendarEvent: nil,
                echoSuppressionApplied: true,
                recoveryManifestPath: nil,
                stagedInputPath: nil,
                finalizedAudioPath: nil,
                segmentAudioPaths: [],
                metadataPath: nil
            ),
            checkpoint: checkpoint
        )
    }

    @Test
    func roundTripsVerifiedJobAndMonotonicCheckpoint() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let store = ProcessingJobStore(rootURL: fixture.url)
        var job = makeJob()

        try await store.save(job)
        _ = job.markCompleted(.transcribed, at: Date(timeIntervalSince1970: 200))
        try await store.save(job)

        let loaded = try await store.load(id: job.id)
        #expect(loaded == job)
        #expect(loaded?.hasDurableTranscription == true)
    }

    @Test
    func stagesTemporaryInputBeforeDeletingOriginal() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let original = fixture.url.appendingPathComponent("incoming.wav")
        let bytes = Data("audio".utf8)
        try bytes.write(to: original)
        let store = ProcessingJobStore(rootURL: fixture.url.appendingPathComponent("jobs"))

        let created = try await store.create(makeJob(), stagingInputURL: original)

        let stagedPath = try #require(created.source.stagedInputPath)
        let staged = URL(fileURLWithPath: stagedPath)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: staged) == bytes)
        #expect(try await store.load(id: created.id) == created)
    }

    @Test
    func discoveryLeavesCorruptFutureAndMismatchedJobsUntouched() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let store = ProcessingJobStore(rootURL: fixture.url)

        let corruptID = UUID()
        let corruptURL = try manifestURL(for: corruptID, root: fixture.url)
        let corruptBytes = Data("not json".utf8)
        try corruptBytes.write(to: corruptURL)

        let future = makeJob(version: PersistedProcessingJob.currentVersion + 1)
        let futureURL = try manifestURL(for: future.id, root: fixture.url)
        try JSONEncoder().encode(future).write(to: futureURL)

        let futureCheckpointVersion = ProcessingCheckpoint.currentVersion + 10
        let futureCheckpointID = UUID()
        let futureCheckpoint = makeJob(
            id: futureCheckpointID,
            checkpoint: ProcessingCheckpoint(
                version: futureCheckpointVersion,
                jobID: futureCheckpointID,
                updatedAt: Date()
            )
        )
        let futureCheckpointURL = try manifestURL(
            for: futureCheckpoint.id,
            root: fixture.url
        )
        try JSONEncoder().encode(futureCheckpoint).write(to: futureCheckpointURL)

        let mismatchedID = UUID()
        let mismatch = makeJob(
            id: mismatchedID,
            checkpoint: ProcessingCheckpoint(jobID: UUID(), updatedAt: Date())
        )
        let mismatchURL = try manifestURL(for: mismatch.id, root: fixture.url)
        try JSONEncoder().encode(mismatch).write(to: mismatchURL)

        let discovery = await store.discover()

        #expect(discovery.jobs.isEmpty)
        #expect(discovery.issues.map(\.kind).contains(.corrupt))
        #expect(discovery.issues.map(\.kind).contains(.unsupportedVersion(future.version)))
        #expect(discovery.issues.map(\.kind).contains(.unsupportedVersion(futureCheckpointVersion)))
        #expect(discovery.issues.map(\.kind).contains(.mismatchedIdentifier))
        #expect(try Data(contentsOf: corruptURL) == corruptBytes)
        #expect(FileManager.default.fileExists(atPath: futureURL.path))
        #expect(FileManager.default.fileExists(atPath: futureCheckpointURL.path))
        #expect(FileManager.default.fileExists(atPath: mismatchURL.path))
    }

    @Test
    func launchRecoveryNeverReplaysPastThePhase5ABoundary() {
        var unfinished = makeJob()
        #expect(unfinished.launchRecoveryAction == .resumeToPhase5ABoundary)

        _ = unfinished.markCompleted(.audioFinalized, at: Date(timeIntervalSince1970: 200))
        #expect(unfinished.launchRecoveryAction == .resumeToPhase5ABoundary)

        _ = unfinished.markCompleted(.transcribed, at: Date(timeIntervalSince1970: 300))
        #expect(unfinished.launchRecoveryAction == .parkAtPhase5ABoundary)

        unfinished.markFailed(.transcription, at: Date(timeIntervalSince1970: 400))
        #expect(unfinished.launchRecoveryAction == .none)

        var finalizationOnly = makeJob()
        finalizationOnly.request = .init(
            transcribe: false,
            summary: false,
            actionItems: false,
            tags: false,
            titleWasUserProvided: false,
            autoResume: true
        )
        _ = finalizationOnly.markCompleted(.audioFinalized, at: Date(timeIntervalSince1970: 200))
        #expect(finalizationOnly.launchRecoveryAction == .parkAtPhase5ABoundary)
    }

    private func manifestURL(for id: UUID, root: URL) throws -> URL {
        let directory = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(ProcessingJobStore.manifestFileName)
    }
}

private struct TemporaryFixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("processing-job-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
