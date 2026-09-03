import Foundation
import Testing
@testable import dBrief

@Suite("Processing recovery")
struct ProcessingRecoveryTests {
    @Test
    func findsFinalizedMasterByStableRecordingID() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("processing-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let recordingID = UUID()
        let audio = folder.appendingPathComponent("meeting.m4a")
        let segment = folder.appendingPathComponent("meeting_part01.m4a")
        let metadata = folder.appendingPathComponent("meeting.json")
        try Data("master".utf8).write(to: audio)
        try Data("segment".utf8).write(to: segment)
        let payload = RecordingMetadataPayload(
            recordingID: recordingID,
            dateISO8601: "2026-09-03T12:00:00Z",
            durationSeconds: 60,
            meetingTitle: "Meeting",
            masterFileName: audio.lastPathComponent,
            segmentFileNames: [segment.lastPathComponent],
            warnings: []
        )
        try JSONEncoder().encode(payload).write(to: metadata)

        let match = RecordingManager.findFinalizedRecording(
            recordingID: recordingID,
            in: folder
        )

        #expect(match?.audioURL.resolvingSymlinksInPath().path == audio.resolvingSymlinksInPath().path)
        #expect(match?.metadataURL.resolvingSymlinksInPath().path == metadata.resolvingSymlinksInPath().path)
        #expect(match?.segmentURLs.map { $0.resolvingSymlinksInPath().path }
            == [segment.resolvingSymlinksInPath().path])
        #expect(RecordingManager.findFinalizedRecording(
            recordingID: UUID(),
            in: folder
        ) == nil)
    }

    @Test
    func legacyMetadataWithoutRecordingIDStillDecodes() throws {
        let legacy = """
        {
          "dateISO8601": "2026-09-03T12:00:00Z",
          "durationSeconds": 60,
          "meetingTitle": "Legacy",
          "masterFileName": "legacy.m4a",
          "segmentFileNames": [],
          "warnings": []
        }
        """

        let decoded = try JSONDecoder().decode(
            RecordingMetadataPayload.self,
            from: Data(legacy.utf8)
        )
        #expect(decoded.recordingID == nil)
    }
}
