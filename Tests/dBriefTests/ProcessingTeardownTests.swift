import Foundation
import Testing
@testable import dBrief

@Suite("Processing teardown")
struct ProcessingTeardownTests {
    private actor Audit {
        var calls: [String] = []
        var committed: PersistedProcessingJob?
        func add(_ value: String) { calls.append(value) }
        func publish(_ record: PersistedProcessingJob) { committed = record; calls.append("publish") }
    }
    private func request(completed: Bool = true, succeeded: Bool = true, stamp: Bool = true) -> ProcessingPipeline.TeardownRequest {
        let id = UUID()
        let record = PersistedProcessingJob(id: id, recordingID: UUID(), createdAt: .distantPast, updatedAt: .distantPast,
            status: .running, request: .init(transcribe: true, summary: false, actionItems: false, tags: false,
                titleWasUserProvided: false, autoResume: false),
            source: .init(recordingDate: .distantPast, duration: 10, fileSize: 1, meetingTitle: "Fixture", associatedApp: nil,
                participants: [], calendarEvent: nil, echoSuppressionApplied: false, recoveryManifestPath: nil,
                stagedInputPath: nil, finalizedAudioPath: nil, segmentAudioPaths: [], metadataPath: nil))
        return .init(completed: completed, processingSucceeded: succeeded, record: record,
                     completion: stamp ? .init(jobID: id, completedAt: Date(timeIntervalSince1970: 100)) : nil,
                     queuedAudioURL: URL(fileURLWithPath: "/synthetic/audio.m4a"))
    }
    private func steps(_ audit: Audit) -> ProcessingPipeline.TeardownSteps {
        .init(saveRecord: { _ in await audit.add("save") }, publishRecord: { await audit.publish($0) },
              saveCompletion: { _ in await audit.add("completion") }, removeQueue: { _ in await audit.add("remove") },
              warning: { await audit.add($0 == .journal ? "journalWarning" : "metadataWarning") })
    }

    @Test func successfulTeardownPersistsBeforeRemovingQueue() async throws {
        let audit = Audit()
        let input = request()
        try await ProcessingPipeline().teardown(input, steps: steps(audit))
        #expect(await audit.calls == ["save", "publish", "completion", "remove"])
        let committed = try #require(await audit.committed)
        #expect(committed.status == .completed && committed.completedAt == input.completion?.completedAt)
    }
    @Test func failedOrHeldWorkflowDoesNotAdvanceCompletionOrRemoveQueue() async throws {
        let audit = Audit()
        try await ProcessingPipeline().teardown(request(completed: false), steps: steps(audit))
        #expect(await audit.calls.isEmpty)
    }
    @Test(arguments: [false, true])
    func unprovenOrFailedWorkflowCannotWriteSuccessfulCompletion(hasStamp: Bool) async throws {
        let audit = Audit()
        try await ProcessingPipeline().teardown(request(succeeded: !hasStamp, stamp: hasStamp), steps: steps(audit))
        #expect(await audit.calls == ["save", "publish", "remove"])
        #expect(await audit.committed?.completedAt == nil)
    }
    @Test(arguments: [false, true])
    func completionWriteFailureWarnsAndPreservesExistingBestEffortTeardown(metadata: Bool) async throws {
        let audit = Audit()
        var actions = steps(audit)
        if metadata { actions.saveCompletion = { _ in throw CocoaError(.fileWriteOutOfSpace) } }
        else { actions.saveRecord = { _ in throw CocoaError(.fileWriteOutOfSpace) } }
        try await ProcessingPipeline().teardown(request(), steps: actions)
        #expect(await audit.calls == (metadata ? ["save", "publish", "metadataWarning", "remove"] : ["journalWarning", "completion", "remove"]))
    }
    @Test(arguments: ["save", "publish", "completion", "remove", "warning"])
    func cancellationStopsFurtherTeardownEffects(boundary: String) async throws {
        let audit = Audit()
        var actions = steps(audit)
        switch boundary {
        case "save": actions.saveRecord = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        case "publish": actions.publishRecord = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        case "completion": actions.saveCompletion = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        case "remove": actions.removeQueue = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        default:
            actions.saveRecord = { _ in throw CocoaError(.fileWriteOutOfSpace) }
            actions.warning = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        let input = actions
        let task = Task { try await ProcessingPipeline().teardown(request(), steps: input) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!(await audit.calls).contains("remove"))
    }
    @Test(arguments: [false, true])
    func replacementAfterJournalSaveStopsPublicationAndQueueRemoval(saveFails: Bool) async throws {
        let audit = Audit()
        var actions = steps(audit)
        actions.saveRecord = { _ in
            await audit.add("save")
            if saveFails { throw CocoaError(.fileWriteOutOfSpace) }
        }
        actions.validateOwnership = { if (await audit.calls).contains("save") { throw CancellationError() } }
        await #expect(throws: CancellationError.self) {
            try await ProcessingPipeline().teardown(request(), steps: actions)
        }
        #expect(await audit.calls == ["save"])
    }

    @Test @MainActor func durableTeardownRemovesOnlyItsQueueMarkerAndRetainsPrivacyScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("meeting.m4a")
        let marker = root.appendingPathComponent("meeting.queue.json")
        let other = root.appendingPathComponent("other.queue.json")
        for url in [audio, marker, other] { try Data("fixture".utf8).write(to: url) }
        let original = request()
        let input = ProcessingPipeline.TeardownRequest(completed: true, processingSucceeded: true,
            record: original.record, completion: original.completion, queuedAudioURL: audio)
        let store = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        let audit = Audit()
        let context = PrivacyTrace.Context(receiptURL: root.appendingPathComponent("privacy.json"), recordingID: UUID())
        let actions = ProcessingPipeline.TeardownSteps(
            saveRecord: { record in
                try await store.save(record)
                #expect(PrivacyTrace.context?.runID == context.runID)
            }, publishRecord: { @MainActor record async throws in
                MainActor.preconditionIsolated()
                #expect(PrivacyTrace.context?.runID == context.runID)
                #expect(try await store.load(id: record.id) == record)
                #expect(FileManager.default.fileExists(atPath: marker.path))
                await audit.publish(record)
            }, saveCompletion: { @MainActor stamp in
                #expect(PrivacyTrace.context?.recordingID == context.recordingID)
                #expect(stamp == input.completion)
                #expect(FileManager.default.fileExists(atPath: marker.path))
                await audit.add("completion")
            }, warning: { _ in Issue.record("Unexpected teardown warning") },
            validateOwnership: { @MainActor in
                MainActor.preconditionIsolated()
                #expect(PrivacyTrace.context?.runID == context.runID)
            })
        try await PrivacyTrace.$context.withValue(context) {
            try await ProcessingPipeline().teardown(input, steps: actions)
        }
        let originalRecord = try #require(input.record)
        let saved = try #require(try await store.load(id: originalRecord.id))
        #expect(saved.status == .completed)
        #expect(saved.completedAt == input.completion?.completedAt)
        #expect(await audit.calls == ["publish", "completion"])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        for url in [audio, other] { #expect(try Data(contentsOf: url) == Data("fixture".utf8)) }
    }
}
