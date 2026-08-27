import Foundation
import Testing
@testable import dBrief

struct CalendarEventTests {
    private func person(_ name: String, _ email: String?) -> CalendarEvent.Person {
        CalendarEvent.Person(name: name, email: email)
    }

    private func event(
        attendees: [CalendarEvent.Person] = [],
        organizer: CalendarEvent.Person? = nil,
        body: String = "",
        location: String? = nil,
        isOnline: Bool? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            title: "Sync",
            attendees: attendees,
            organizer: organizer,
            body: body,
            location: location,
            isOnline: isOnline,
            startDate: Date(),
            endDate: Date()
        )
    }

    // MARK: - attendeeNames

    @Test
    func attendeeNamesListsAttendees() {
        let e = event(attendees: [person("Alice", "alice@acme.com"), person("Bob", nil)])
        #expect(e.attendeeNames == ["Alice", "Bob"])
    }

    /// Directory calendars hand us "Last, First"; one attendee must stay one name.
    @Test
    func attendeeNamesNormalizeDirectoryStyleNames() {
        let e = event(attendees: [person("den Boer, Bart", "bart@acme.com"),
                                  person("De Roni, Marco", nil)])
        #expect(e.attendeeNames == ["Bart den Boer", "Marco De Roni"])
    }

    @Test
    func attendeeNamesDropBlanksAndDuplicates() {
        let e = event(attendees: [person("Alice", nil), person("  ", nil), person("alice", nil)])
        #expect(e.attendeeNames == ["Alice"])
    }

    // MARK: - modality

    @Test
    func modalityOnlineWhenFlagged() {
        #expect(event(isOnline: true).modality == "online")
    }

    @Test
    func modalityOnsiteWhenLocationPresentAndNotOnline() {
        #expect(event(location: "Room 4").modality == "onsite")
    }

    @Test
    func modalityUnknownWhenNoSignal() {
        #expect(event().modality == "unknown")
    }

    @Test
    func modalityOnlinePrecedesLocation() {
        #expect(event(location: "Room 4", isOnline: true).modality == "online")
    }

    // MARK: - external participants

    @Test
    func externalParticipantsDetectedByDomain() {
        let e = event(
            attendees: [person("Alice", "alice@acme.com"), person("Carol", "carol@customer.com")],
            organizer: person("Alice", "alice@acme.com")
        )
        #expect(e.hasExternalParticipants)
        #expect(e.externalDomains == ["customer.com"])
    }

    @Test
    func noExternalParticipantsWhenAllShareOrganizerDomain() {
        let e = event(
            attendees: [person("Alice", "alice@acme.com"), person("Bob", "bob@acme.com")],
            organizer: person("Alice", "alice@acme.com")
        )
        #expect(!e.hasExternalParticipants)
        #expect(e.externalDomains.isEmpty)
    }

    @Test
    func externalDomainsEmptyWhenOrganizerEmailUnknown() {
        let e = event(
            attendees: [person("Carol", "carol@customer.com")],
            organizer: person("Alice", nil)
        )
        #expect(e.externalDomains.isEmpty)
    }

    // MARK: - online detection

    @Test
    func looksOnlineMatchesKnownHosts() {
        #expect(CalendarEvent.looksOnline("Join: https://acme.zoom.us/j/123"))
        #expect(CalendarEvent.looksOnline("https://teams.microsoft.com/l/meetup"))
        #expect(!CalendarEvent.looksOnline("Conference Room B"))
        #expect(!CalendarEvent.looksOnline(nil))
    }

    @Test
    func emailDomainParsing() {
        #expect(person("X", "x@Example.COM").emailDomain == "example.com")
        #expect(person("X", "no-at-sign").emailDomain == nil)
        #expect(person("X", nil).emailDomain == nil)
    }

    // MARK: - Webhook payload

    private func bundle(calendarEvent: CalendarEvent?) -> IntegrationContentBundle {
        IntegrationContentBundle(
            title: "Sync",
            createdAt: Date(),
            durationSeconds: 60,
            audioFileURL: URL(fileURLWithPath: "/tmp/a.m4a"),
            transcript: nil,
            summary: nil,
            actionItems: [],
            tags: [],
            sentiment: nil,
            markdown: nil,
            calendarEvent: calendarEvent
        )
    }

    @Test
    func webhookPayloadIncludesMeetingWhenFieldSelected() throws {
        let e = event(
            attendees: [person("Alice", "alice@acme.com"), person("Carol", "carol@customer.com")],
            organizer: person("Alice", "alice@acme.com"),
            body: "Discuss roadmap",
            location: "Room 4"
        )
        let payload = WebhookPayloadBuilder().payloadDictionary(
            recordingID: UUID(),
            fileName: "a.m4a",
            createdAt: Date(),
            durationSeconds: 60,
            bundle: bundle(calendarEvent: e),
            fields: [.meetingInfo]
        )

        let meeting = try #require(payload["meeting"] as? [String: Any])
        #expect(meeting["agenda"] as? String == "Discuss roadmap")
        #expect(meeting["location"] as? String == "Room 4")
        #expect(meeting["external_participants"] as? Bool == true)
        let attendees = meeting["attendees"] as? [[String: Any]]
        #expect(attendees?.count == 2)
        #expect(attendees?.first?["email"] as? String == "alice@acme.com")
        let organizer = meeting["organizer"] as? [String: Any]
        #expect(organizer?["name"] as? String == "Alice")
    }

    @Test
    func webhookPayloadOmitsMeetingWhenFieldNotSelected() {
        let payload = WebhookPayloadBuilder().payloadDictionary(
            recordingID: UUID(),
            fileName: "a.m4a",
            createdAt: Date(),
            durationSeconds: 60,
            bundle: bundle(calendarEvent: event(location: "Room 4")),
            fields: [.summary]
        )
        #expect(payload["meeting"] == nil)
    }

    @Test
    func webhookPayloadOmitsMeetingWhenNoEvent() {
        let payload = WebhookPayloadBuilder().payloadDictionary(
            recordingID: UUID(),
            fileName: "a.m4a",
            createdAt: Date(),
            durationSeconds: 60,
            bundle: bundle(calendarEvent: nil),
            fields: [.meetingInfo]
        )
        #expect(payload["meeting"] == nil)
    }

    // MARK: - Markdown output

    @MainActor
    @Test
    func markdownIncludesCalendarFrontmatterAndSections() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let recording = Recording(fileURL: dir.appendingPathComponent("rec.m4a"))
        recording.generatedTitle = "Weekly Sync"
        recording.summary = "We talked."
        recording.calendarEvent = event(
            attendees: [person("Alice", "alice@acme.com"), person("Carol", "carol@customer.com")],
            organizer: person("Alice", "alice@acme.com"),
            body: "Discuss Q2 roadmap",
            location: "Room 4"
        )

        let url = try MarkdownGenerator().generate(
            recording: recording,
            outputFolder: dir,
            transcriptionEndpoint: nil,
            aiEndpoint: nil
        )
        let md = try String(contentsOf: url, encoding: .utf8)

        #expect(md.contains("organizer: \"Alice\""))
        #expect(md.contains("attendees:"))
        #expect(md.contains("attendee_emails:"))
        #expect(md.contains("alice@acme.com"))
        #expect(md.contains("meeting_modality: \"onsite\""))
        #expect(md.contains("location: \"Room 4\""))
        #expect(md.contains("external_participants: true"))
        #expect(md.contains("## 👥 Attendees"))
        #expect(md.contains("## 📋 Agenda"))
        #expect(md.contains("Discuss Q2 roadmap"))

        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    @Test
    func markdownWithoutCalendarEventHasNoCalendarFields() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let recording = Recording(fileURL: dir.appendingPathComponent("rec.m4a"))
        recording.generatedTitle = "Solo Note"
        recording.summary = "Just me."

        let url = try MarkdownGenerator().generate(
            recording: recording,
            outputFolder: dir,
            transcriptionEndpoint: nil,
            aiEndpoint: nil
        )
        let md = try String(contentsOf: url, encoding: .utf8)

        #expect(!md.contains("meeting_modality"))
        #expect(!md.contains("attendees:"))
        #expect(!md.contains("## 👥 Attendees"))
        #expect(!md.contains("## 📋 Agenda"))

        try? FileManager.default.removeItem(at: dir)
    }
}
