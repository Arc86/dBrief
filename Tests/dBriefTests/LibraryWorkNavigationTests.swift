import Foundation
import Testing
@testable import dBrief

@Suite("Smart-view work navigation")
struct LibraryWorkNavigationTests {
    private func job(id: UUID = UUID(), audio: URL? = nil) -> PersistedProcessingJob {
        .init(id: id, recordingID: UUID(), createdAt: .now, updatedAt: .now, status: .failed,
            request: .init(transcribe: true, summary: false, actionItems: false, tags: false, titleWasUserProvided: false, autoResume: false),
            source: .init(recordingDate: .now, duration: 1, fileSize: 1, meetingTitle: "Recovery", associatedApp: nil,
                participants: [], calendarEvent: nil, echoSuppressionApplied: false, recoveryManifestPath: nil,
                stagedInputPath: nil, finalizedAudioPath: audio?.path, segmentAudioPaths: [], metadataPath: nil))
    }

    private func item(id: UUID, target: LibraryWorkItem.Target, audio: URL? = nil, source: String? = nil) -> LibraryWorkItem {
        .init(id: "row", recoveryID: id, target: target, title: "Cached title", audioURL: audio, date: .now,
            status: "Cached status", failed: true, sourcePath: source, associatedApp: "")
    }

    @Test func staleProcessingRowUsesCurrentDeliveryAndRejectsCompletedOrDismissedWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        let deliveries = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries"))
        let audio = root.appendingPathComponent("missing.wav")
        var saved = job(audio: audio)
        try await jobs.save(saved)
        let row = item(id: saved.id, target: .recovery)
        #expect(try await LibraryWorkNavigation.resolve(row, jobs: jobs, deliveries: deliveries) == .processing(saved.id))
        var batch = IntegrationDeliveryBatch(id: saved.id, recordingID: saved.recordingID, createdAt: .now,
            bundle: .init(title: "Frozen", createdAt: .now, durationSeconds: 1, audioFileURL: audio, transcript: "", summary: "",
                actionItems: [], tags: [], sentiment: nil, markdown: "", calendarEvent: nil),
            deliveries: [.init(id: UUID(), destination: .webhook, configurationDigest: "config", status: .uncertain)])
        try await deliveries.save(batch)
        #expect(try await LibraryWorkNavigation.resolve(row, jobs: jobs, deliveries: deliveries) == .delivery(saved.id, audio))
        saved.dismissedFromQueue = true
        try await jobs.save(saved)
        await #expect(throws: (any Error).self) { try await LibraryWorkNavigation.resolve(row, jobs: jobs, deliveries: deliveries) }
        saved.dismissedFromQueue = false
        saved.status = .completed
        try await jobs.save(saved)
        batch.deliveries[0].status = .succeeded
        try await deliveries.save(batch)
        await #expect(throws: (any Error).self) { try await LibraryWorkNavigation.resolve(row, jobs: jobs, deliveries: deliveries) }
    }

    @Test func queueNavigationRequiresTheSameMarkerIdentityAndAvailableAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        let deliveries = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries"))
        let audio = root.appendingPathComponent("queue.wav")
        try Data([1]).write(to: audio)
        let marker = audio.deletingPathExtension().appendingPathExtension("queue.json")
        var queued = QueueItem(transcribe: true, summary: false, actionItems: false, tags: false)
        try JSONEncoder().encode(queued).write(to: marker)
        let row = item(id: queued.id, target: .queue, audio: audio, source: marker.path)
        #expect(try await LibraryWorkNavigation.resolve(row, jobs: jobs, deliveries: deliveries) == .queue(queued.id, audio))
        try FileManager.default.removeItem(at: audio)
        await #expect(throws: (any Error).self) { try await LibraryWorkNavigation.resolve(row, jobs: jobs, deliveries: deliveries) }
        try Data([1]).write(to: audio)
        queued.id = UUID()
        try JSONEncoder().encode(queued).write(to: marker)
        await #expect(throws: (any Error).self) { try await LibraryWorkNavigation.resolve(row, jobs: jobs, deliveries: deliveries) }
    }

    @Test func captureNavigationCannotRecoverAJobOwnedOrMissingSessionTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        let deliveries = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries"))
        let sessions = root.appendingPathComponent("sessions")
        let id = UUID()
        let session = try InterruptedSessionStore.createSession(id: id, startedAt: .now, rootURL: sessions)
        try Data([1]).write(to: session.directoryURL.appendingPathComponent("capture.mic.caf"))
        let row = item(id: id, target: .capture, source: session.manifestURL.path)
        #expect(try await LibraryWorkNavigation.resolve(row, jobs: jobs, deliveries: deliveries, sessionsRoot: sessions) == .capture(id))
        var owner = job()
        owner.source.recoveryManifestPath = session.manifestURL.path
        try await jobs.save(owner)
        #expect(try await LibraryWorkNavigation.resolve(row, jobs: jobs, deliveries: deliveries, sessionsRoot: sessions) == .processing(owner.id))
        owner.status = .completed
        try await jobs.save(owner)
        await #expect(throws: (any Error).self) { try await LibraryWorkNavigation.resolve(row, jobs: jobs, deliveries: deliveries, sessionsRoot: sessions) }
    }
    @Test func cancelledNavigationNeverReturnsAnAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        let deliveries = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries"))
        let saved = job()
        try await jobs.save(saved)
        let row = item(id: saved.id, target: .recovery)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LibraryWorkNavigation.resolve(row, jobs: jobs, deliveries: deliveries)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: [LibraryWorkItem.Target.recovery, .capture])
    func cancellingDuringDeliveryLookupCannotReturnARecoveryAction(target: LibraryWorkItem.Target) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
        let saved = job()
        try await jobs.save(saved)
        let deliveries = SuspendedDeliveryLookup()
        let row = item(id: target == .capture ? saved.recordingID : saved.id, target: target)
        let task = Task {
            try await LibraryWorkNavigation.resolve(row, jobs: jobs, deliveries: deliveries,
                sessionsRoot: root.appendingPathComponent("sessions"))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await deliveries.entered) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await deliveries.entered)
        task.cancel()
        await deliveries.release()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

}


private actor SuspendedDeliveryLookup: IntegrationDeliveryPersistence {
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func load(id: UUID) async throws -> IntegrationDeliveryBatch? {
        entered = true
        if !released { await withCheckedContinuation { waiter = $0 } }
        return nil
    }
    func save(_ batch: IntegrationDeliveryBatch) async throws { }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
