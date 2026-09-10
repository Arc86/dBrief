import Foundation
import Testing
@testable import dBrief

@Suite("Saved calendar links")
struct CalendarLinkTests {
    @Test func linkSurvivesReloadAndPreservesCustomFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("meeting.wav")
        let url = root.appendingPathComponent("meeting.json")
        let payload = RecordingMetadataPayload(dateISO8601: "2026-09-08T09:00:00Z", durationSeconds: 60,
            meetingTitle: "Custom", masterFileName: "meeting.wav", segmentFileNames: [], warnings: [],
            generatedTitle: "My title", participants: ["Alex"])
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        object["futureField"] = "keep"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let event = CalendarEvent(title: "Planning", attendees: [.init(name: "Sam", email: "sam@example.com")],
            body: "Discuss next quarter", startDate: Date(timeIntervalSince1970: 100), endDate: Date(timeIntervalSince1970: 200))
        let store = RecordingMetadataStore()
        try await store.linkCalendar(event, audioURL: audio, updateTitle: false, updateParticipants: false)
        let saved = try #require(try await store.load(audioURL: audio))
        #expect(saved.calendarEvent == event)
        #expect(saved.generatedTitle == "My title")
        #expect(saved.participants == ["Alex"])
        #expect(saved.calendarAttendees == ["Sam"])
        object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["futureField"] as? String == "keep")
        try await store.linkCalendar(event, audioURL: audio, updateTitle: true, updateParticipants: true)
        let replaced = try #require(try await store.load(audioURL: audio))
        #expect(replaced.meetingTitle == "Planning")
        #expect(replaced.generatedTitle == "Planning")
        #expect(replaced.participants == ["Sam"])
    }

    @Test func missingOrCorruptMetadataCannotReportSuccessfulLink() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let url = audio.deletingPathExtension().appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }
        let event = CalendarEvent(title: "Meeting", attendees: [], body: "", startDate: .now, endDate: .now)
        let store = RecordingMetadataStore()
        await #expect(throws: (any Error).self) {
            try await store.linkCalendar(event, audioURL: audio, updateTitle: true, updateParticipants: true)
        }
        try Data("broken".utf8).write(to: url)
        await #expect(throws: (any Error).self) {
            try await store.linkCalendar(event, audioURL: audio, updateTitle: true, updateParticipants: true)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
    }
}
