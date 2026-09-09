import Foundation
import Testing
@testable import dBrief

@Suite("Recovered recording sources")
struct RecordingRecoverySourceTests {
    private final class ProbeFileManager: FileManager, @unchecked Sendable {
        let cancelAtPath: String?
        init(cancelAtPath: String? = nil) { self.cancelAtPath = cancelAtPath; super.init() }
        override func fileExists(atPath path: String) -> Bool {
            #expect(!Thread.isMainThread)
            if path == cancelAtPath {
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            }
            return super.fileExists(atPath: path)
        }
    }
    private func source() -> PersistedProcessingJob.Source {
        .init(recordingDate: .distantPast, duration: 9, fileSize: 17, meetingTitle: "Saved title", associatedApp: nil,
              participants: [], calendarEvent: nil, echoSuppressionApplied: false, recoveryManifestPath: nil,
              stagedInputPath: nil, finalizedAudioPath: nil, segmentAudioPaths: [], metadataPath: nil)
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test @MainActor func finalizedMasterWinsAndOnlyExistingSegmentsAreRestored() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("master.m4a"), segment = root.appendingPathComponent("master_part01.m4a")
        try Data("master".utf8).write(to: audio); try Data("segment".utf8).write(to: segment)
        var saved = source()
        saved.finalizedAudioPath = audio.path
        saved.stagedInputPath = root.appendingPathComponent("stale-input").path
        saved.segmentAudioPaths = [segment.path, root.appendingPathComponent("missing.m4a").path]
        saved.metadataPath = root.appendingPathComponent("master.json").path
        let recovered = try #require(try await ProcessingPipeline().recoverRecordingSource(recordingID: UUID(), source: saved,
            recordingFolder: root, recoveryRoot: root.appendingPathComponent("recovery"), fileManager: ProbeFileManager()))
        #expect(recovered.finalizedAudioURL == audio)
        #expect(recovered.segmentAudioURLs == [segment])
        #expect(recovered.fileSize == 6 && recovered.duration == 9)
        #expect(recovered.importSourceURL == nil && recovered.capturedTracks == nil)
    }
    @Test func crashWindowMetadataMatchTakesPrecedenceOverConsumedStaging() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), audio = root.appendingPathComponent("relocated.wav")
        try Data("audio".utf8).write(to: audio)
        try JSONEncoder().encode(RecordingMetadataPayload(recordingID: id, dateISO8601: "2026-09-09T00:00:00Z",
            durationSeconds: 9, meetingTitle: "Recovered", masterFileName: audio.lastPathComponent,
            segmentFileNames: ["../escape.wav", "missing.wav"], warnings: []))
            .write(to: root.appendingPathComponent("relocated.json"))
        var saved = source(); saved.finalizedAudioPath = root.appendingPathComponent("old.wav").path
        saved.stagedInputPath = root.appendingPathComponent("consumed.wav").path
        let recovered = try #require(try await ProcessingPipeline().recoverRecordingSource(recordingID: id, source: saved,
            recordingFolder: root, recoveryRoot: root.appendingPathComponent("recovery")))
        #expect(recovered.finalizedAudioURL?.lastPathComponent == audio.lastPathComponent)
        #expect(recovered.segmentAudioURLs.isEmpty && recovered.importSourceURL == nil)
    }
    @Test func stagedImportRetainsSavedMeasurementsAndMissingStagingDoesNotFallThrough() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("input.wav")
        try Data("audio".utf8).write(to: stage)
        var saved = source(); saved.stagedInputPath = stage.path
        let pipeline = ProcessingPipeline()
        let recovered = try #require(try await pipeline.recoverRecordingSource(recordingID: UUID(), source: saved,
            recordingFolder: root, recoveryRoot: root.appendingPathComponent("recovery")))
        #expect(recovered.importSourceURL == stage && recovered.finalizedAudioURL == nil)
        #expect(recovered.duration == 9 && recovered.fileSize == 17)
        try FileManager.default.removeItem(at: stage)
        #expect(try await pipeline.recoverRecordingSource(recordingID: UUID(), source: saved,
            recordingFolder: root, recoveryRoot: root.appendingPathComponent("recovery")) == nil)
    }
    @Test @MainActor func capturedTracksRecoverTheirManifestSizeDurationAndPrivacyContext() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let recoveryRoot = root.appendingPathComponent("recovery")
        let session = try InterruptedSessionStore.createSession(id: UUID(), startedAt: .distantPast, rootURL: recoveryRoot)
        let mic = session.directoryURL.appendingPathComponent("capture.mic.caf")
        try Data(repeating: 1, count: 5000).write(to: mic)
        var saved = source(); saved.duration = 0; saved.recoveryManifestPath = session.manifestURL.path
        let input = saved
        let recordingID = UUID()
        let context = PrivacyTrace.Context(receiptURL: root.appendingPathComponent("privacy.json"), recordingID: recordingID)
        let pipeline = ProcessingPipeline(duration: { url in
            #expect(url.lastPathComponent == mic.lastPathComponent)
            #expect(PrivacyTrace.context?.runID == context.runID)
            return 15
        })
        let recovered = try #require(try await PrivacyTrace.$context.withValue(context) {
            try await pipeline.recoverRecordingSource(recordingID: recordingID, source: input,
                recordingFolder: root.appendingPathComponent("library"), recoveryRoot: recoveryRoot)
        })
        #expect(recovered.fileSize == 5000 && recovered.duration == 15)
        #expect(recovered.capturedTracks?.micURL?.lastPathComponent == mic.lastPathComponent)
        #expect(recovered.recoveryManifestURL?.lastPathComponent == session.manifestURL.lastPathComponent)
        #expect(recovered.finalizedAudioURL == nil)
    }
    @Test func cancelledRecoveryIsDistinctFromMissingInput() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessingPipeline().recoverRecordingSource(recordingID: UUID(), source: source(),
                recordingFolder: root, recoveryRoot: root)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func cancellationDuringMissingStagedLookupCannotBecomeMissingInput() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var saved = source()
        let missing = root.appendingPathComponent("missing.wav")
        saved.stagedInputPath = missing.path
        let input = saved
        let task = Task {
            try await ProcessingPipeline().recoverRecordingSource(recordingID: UUID(), source: input,
                recordingFolder: root, recoveryRoot: root,
                fileManager: ProbeFileManager(cancelAtPath: missing.path))
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

}
