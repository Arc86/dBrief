import Foundation
import Testing
@testable import dBrief

@Suite("Stable processing completion")
struct ProcessingCompletionTests {
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("processing-completion-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func fallback(_ audio: URL, id: UUID = UUID()) -> RecordingMetadataPayload {
        .init(recordingID: id, dateISO8601: "2026-09-01T09:00:00Z", durationSeconds: 10, meetingTitle: "Fixture",
            masterFileName: audio.lastPathComponent, segmentFileNames: [], warnings: [], generatedTitle: "Keep title", participants: ["Alice"])
    }

    private func batch(audio: URL) -> IntegrationDeliveryBatch {
        .init(id: UUID(), recordingID: UUID(), createdAt: .distantPast,
            bundle: .init(title: "Fixture", createdAt: .distantPast, durationSeconds: 10, audioFileURL: audio,
                transcript: nil, summary: nil, actionItems: [], tags: [], sentiment: nil, markdown: nil, calendarEvent: nil),
            deliveries: [.init(id: UUID(), destination: .webhook, configurationDigest: "fixture")])
    }
    private func job(status: PersistedProcessingJob.Status = .running) -> PersistedProcessingJob {
        PersistedProcessingJob(id: UUID(), recordingID: UUID(), createdAt: .distantPast, updatedAt: .distantPast,
            status: status, request: .init(transcribe: true, summary: false, actionItems: false, tags: false,
                titleWasUserProvided: false, autoResume: false),
            source: .init(recordingDate: .distantPast, duration: 10, fileSize: 1, meetingTitle: "Fixture", associatedApp: nil,
                participants: [], calendarEvent: nil, echoSuppressionApplied: false,
                recoveryManifestPath: nil, stagedInputPath: nil, finalizedAudioPath: nil, segmentAudioPaths: [], metadataPath: nil))
    }

    @Test func successfulCompletionGetsAStableDateInsteadOfFollowingLaterJournalUpdates() throws {
        var record = job()
        let finished = Date(timeIntervalSince1970: 1_000_000)
        record.markFullyCompleted(at: finished)
        record.markFullyCompleted(at: finished.addingTimeInterval(500))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        let stored = json["completedAt"] as? Double
        #expect(stored == finished.timeIntervalSinceReferenceDate)
    }

    @Test func warningAndLegacyCompletionRemainUndated() throws {
        var legacy = job(status: .completed)
        legacy.markFullyCompleted(at: .now)
        #expect(legacy.completedAt == nil)
        var warning = job()
        warning.markFullyCompleted(at: .now, successful: false)
        #expect(warning.status == .completed)
        #expect(warning.completedAt == nil)
        var successful = job()
        let completed = Date(timeIntervalSince1970: 100)
        successful.markFullyCompleted(at: completed)
        successful.markCancelled(at: completed.addingTimeInterval(50))
        #expect(successful.completedAt == completed)
        #expect(try JSONDecoder().decode(PersistedProcessingJob.self, from: JSONEncoder().encode(successful)).completedAt == completed)
    }

    @Test @MainActor func importsCreateMetadataAndLaterEditsKeepCompletion() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("import.wav")
        try Data([1]).write(to: audio)
        let stamp = ProcessingCompletionStamp(jobID: UUID(), completedAt: Date(timeIntervalSince1970: 100))
        try await RecordingCompletionStore.record(stamp, audioURL: audio, fallback: fallback(audio))
        let metadata = audio.deletingPathExtension().appendingPathExtension("json")
        let payload = try JSONDecoder().decode(RecordingMetadataPayload.self, from: Data(contentsOf: metadata))
        #expect(payload.lastProcessingCompletion == stamp)
        #expect(payload.participants == ["Alice"])
        #expect(payload.masterFileName == "import.wav")
        try await RecordingMetadataStore.shared.update(.generatedTitle("Edited title"), audioURL: audio)
        #expect(try JSONDecoder().decode(RecordingMetadataPayload.self, from: Data(contentsOf: metadata)).lastProcessingCompletion == stamp)
    }

    @Test @MainActor func repeatedOlderAndNewerCompletionsPreserveUserMetadataAndMonotonicTime() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("meeting.m4a")
        try Data([1]).write(to: audio)
        let metadata = audio.deletingPathExtension().appendingPathExtension("json")
        let stableID = UUID()
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fallback(audio, id: stableID))) as? [String: Any])
        object["customField"] = "Keep this"
        try JSONSerialization.data(withJSONObject: object).write(to: metadata)
        let first = ProcessingCompletionStamp(jobID: UUID(), completedAt: Date(timeIntervalSince1970: 200))
        try await RecordingCompletionStore.record(first, audioURL: audio, fallback: fallback(audio))
        try await RecordingCompletionStore.record(.init(jobID: first.jobID, completedAt: Date(timeIntervalSince1970: 900)), audioURL: audio, fallback: fallback(audio))
        try await RecordingCompletionStore.record(.init(jobID: UUID(), completedAt: Date(timeIntervalSince1970: 100)), audioURL: audio, fallback: fallback(audio))
        #expect(try JSONDecoder().decode(RecordingMetadataPayload.self, from: Data(contentsOf: metadata)).lastProcessingCompletion == first)
        let newer = ProcessingCompletionStamp(jobID: UUID(), completedAt: Date(timeIntervalSince1970: 300))
        try await RecordingCompletionStore.record(newer, audioURL: audio, fallback: fallback(audio))
        let latest = try JSONDecoder().decode(RecordingMetadataPayload.self, from: Data(contentsOf: metadata))
        #expect(latest.lastProcessingCompletion == newer)
        #expect(latest.recordingID == stableID)
        #expect(latest.generatedTitle == "Keep title")
        object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        #expect(object["customField"] as? String == "Keep this")
    }

    @Test @MainActor func corruptMetadataAndMissingAudioAreNeverReplaced() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("meeting.wav")
        let metadata = audio.deletingPathExtension().appendingPathExtension("json")
        let stamp = ProcessingCompletionStamp(jobID: UUID(), completedAt: .now)
        await #expect(throws: (any Error).self) { try await RecordingCompletionStore.record(stamp, audioURL: audio, fallback: fallback(audio)) }
        #expect(!FileManager.default.fileExists(atPath: metadata.path))
        try Data([1]).write(to: audio)
        for bytes in [Data("corrupt".utf8), Data("{}".utf8),
                      Data(#"{"durationSeconds":"invalid"}"#.utf8), Data(#"{"lastProcessingCompletion":{"unknown":true}}"#.utf8)] {
            try bytes.write(to: metadata)
            await #expect(throws: (any Error).self) { try await RecordingCompletionStore.record(stamp, audioURL: audio, fallback: fallback(audio)) }
            #expect(try Data(contentsOf: metadata) == bytes)
        }
    }

    @Test func successfulDeliveryRequiresKnownCleanProcessingPrefixAndAllOutcomes() {
        var saved = batch(audio: URL(fileURLWithPath: "/tmp/fixture.wav"))
        saved.deliveries[0].status = .succeeded
        saved.deliveries[0].updatedAt = Date(timeIntervalSince1970: 200)
        #expect(saved.successfulWorkflowCompletion == nil, "Legacy send success cannot establish processing success")
        saved.processingSucceededBeforeDeliveryAt = Date(timeIntervalSince1970: 100)
        #expect(saved.successfulWorkflowCompletion?.completedAt == Date(timeIntervalSince1970: 200))
        saved.dismissedFromQueue = true
        #expect(saved.successfulWorkflowCompletion?.completedAt == Date(timeIntervalSince1970: 200))
        saved.deliveries[0].status = .uncertain
        #expect(saved.successfulWorkflowCompletion == nil)
        saved.deliveries[0].status = .succeeded
        saved.deliveries[0].updatedAt = nil
        #expect(saved.successfulWorkflowCompletion == nil)
        saved.deliveries = []
        #expect(saved.successfulWorkflowCompletion?.completedAt == Date(timeIntervalSince1970: 100))
    }

    @Test @MainActor func retirementPreservesJobAndIndependentBatchDatesBeforeDeletingJournals() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let jobs = ProcessingJobStore(rootURL: folder.appendingPathComponent("jobs"))
        let deliveries = IntegrationDeliveryStore(rootURL: folder.appendingPathComponent("deliveries"))
        let audio = folder.appendingPathComponent("meeting.wav")
        try Data([1]).write(to: audio)
        var record = job()
        record.source.finalizedAudioPath = audio.path
        let finished = Date(timeIntervalSince1970: 100)
        record.markFullyCompleted(at: finished)
        try await jobs.save(record)
        _ = try await RecoveryLifecycle(jobs: jobs, deliveries: deliveries).prepareRetention(category: .transcripts, days: 1, folders: [folder])
        #expect(try await jobs.load(id: record.id) == nil)
        let metadata = audio.deletingPathExtension().appendingPathExtension("json")
        #expect(try JSONDecoder().decode(RecordingMetadataPayload.self, from: Data(contentsOf: metadata)).lastProcessingCompletion?.completedAt == finished)
        var independent = batch(audio: audio)
        independent.processingSucceededBeforeDeliveryAt = finished.addingTimeInterval(1)
        independent.deliveries[0].status = .succeeded
        independent.deliveries[0].updatedAt = finished.addingTimeInterval(2)
        try await deliveries.save(independent)
        _ = try await RecoveryLifecycle(jobs: jobs, deliveries: deliveries).prepareRetention(category: .transcripts, days: 1, folders: [folder])
        #expect(try await deliveries.load(id: independent.id) == nil)
        #expect(try JSONDecoder().decode(RecordingMetadataPayload.self, from: Data(contentsOf: metadata)).lastProcessingCompletion == independent.successfulWorkflowCompletion)
    }

    @Test @MainActor func retirementFailureRetainsKnownDateForRetry() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let jobs = ProcessingJobStore(rootURL: folder.appendingPathComponent("jobs"))
        let deliveries = IntegrationDeliveryStore(rootURL: folder.appendingPathComponent("deliveries"))
        let audio = folder.appendingPathComponent("meeting.wav")
        try Data([1]).write(to: audio)
        var record = job()
        record.source.finalizedAudioPath = audio.path
        record.markFullyCompleted(at: Date(timeIntervalSince1970: 100))
        try await jobs.save(record)
        let metadata = audio.deletingPathExtension().appendingPathExtension("json")
        try Data("corrupt".utf8).write(to: metadata)
        await #expect(throws: (any Error).self) {
            _ = try await RecoveryLifecycle(jobs: jobs, deliveries: deliveries).prepareRetention(category: .transcripts, days: 1, folders: [folder])
        }
        #expect(try await jobs.load(id: record.id)?.completedAt == record.completedAt)
        #expect(try String(contentsOf: metadata, encoding: .utf8) == "corrupt")
    }
}
