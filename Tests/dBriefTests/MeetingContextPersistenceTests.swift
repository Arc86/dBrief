import Foundation
import Testing
@testable import dBrief

/// The people in a meeting (typed participants + calendar attendees) are session-only on
/// `Recording`. Without them in the metadata sidecar, a recording reopened from the transcript
/// browser offers only voice-library names when assigning speakers.
struct MeetingContextPersistenceTests {

    private func payload(participants: [String], attendees: [String]) -> RecordingMetadataPayload {
        RecordingMetadataPayload(
            dateISO8601: "2026-07-27T10:00:00Z",
            durationSeconds: 90,
            meetingTitle: "Sync",
            masterFileName: "sync.m4a",
            segmentFileNames: [],
            warnings: [],
            participants: participants,
            calendarAttendees: attendees
        )
    }

    @Test
    func payloadRoundTripsMeetingNames() throws {
        let original = payload(participants: ["Bart den Boer"], attendees: ["Marco De Roni"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecordingMetadataPayload.self, from: data)

        #expect(decoded.participants == ["Bart den Boer"])
        #expect(decoded.calendarAttendees == ["Marco De Roni"])
    }

    /// Sidecars written before these fields existed must still decode.
    @Test
    func legacySidecarWithoutMeetingNamesDecodes() throws {
        let legacy = """
        {
          "dateISO8601": "2026-07-27T10:00:00Z",
          "durationSeconds": 90,
          "meetingTitle": "Sync",
          "masterFileName": "sync.m4a",
          "segmentFileNames": [],
          "warnings": []
        }
        """
        let decoded = try JSONDecoder().decode(
            RecordingMetadataPayload.self, from: Data(legacy.utf8))

        #expect(decoded.participants.isEmpty)
        #expect(decoded.calendarAttendees.isEmpty)
    }

    @Test
    func browserItemMergesParticipantsAndAttendeesInOrder() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try writeRecording(
            named: "2026-07-27_1100_tu-e",
            in: folder,
            payload: payload(participants: ["Jesper Mol", "Bart den Boer"],
                             attendees: ["Bart den Boer", "Marco De Roni"]))

        let items = RecordingBrowserStore.load(in: folder)
        #expect(items.count == 1)
        // Typed participants first, calendar attendees after, de-duped.
        #expect(items.first?.meetingNames == ["Jesper Mol", "Bart den Boer", "Marco De Roni"])
    }

    @Test
    func browserItemHasNoMeetingNamesWithoutSidecarFields() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try writeRecording(
            named: "2026-07-27_1200_solo",
            in: folder,
            payload: payload(participants: [], attendees: []))

        #expect(RecordingBrowserStore.load(in: folder).first?.meetingNames == [])
    }

    // MARK: - helpers

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbrief-meeting-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeRecording(
        named stem: String,
        in folder: URL,
        payload: RecordingMetadataPayload
    ) throws {
        let audio = folder.appendingPathComponent("\(stem).m4a")
        try Data("audio".utf8).write(to: audio)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: folder.appendingPathComponent("\(stem).json"))
    }
}
