import Testing
import Foundation
@testable import dBrief

/// Strict decoding and semantic validation of the calendar CLI contract,
/// exercised against sanitized fixtures and synthetic regressions of the
/// observed non-compliant model output.
struct CalendarCLIPromptTests {

    // MARK: - Fixtures and builders

    static let listRequestID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let detailRequestID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let fixtureDirectory = "Fixtures/CalendarCLI"

    static var config: CalendarCLIConfig {
        // Mixed-case on purpose: normalization is part of the contract.
        .default.updating(mailboxEmail: "  Ada.Lovelace@Example.com ")
    }

    static func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("\(fixtureDirectory)/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func utcDate(_ raw: String) -> Date {
        CalendarCLITimeParsing.connectorUTCDate(raw).unsafelyUnwrapped
    }

    static var listWindow: CalendarCLIWindow {
        CalendarCLIWindow(
            start: Self.utcDate("2026-09-22T00:00:00Z"),
            end: Self.utcDate("2026-09-23T00:00:00Z"),
            timeZoneID: "UTC"
        )
    }

    static var detailEntry: CalendarCLIEntry {
        let start = Self.utcDate("2026-09-22T07:15:00.0000000")
        let end = Self.utcDate("2026-09-22T07:45:00.0000000")
        return CalendarCLIEntry(
            key: CalendarCLIOccurrenceKey(
                mailbox: "ada.lovelace@example.com", calendar: "",
                resourceURI: "calendar:///events/FAKE0001?owner=ada.lovelace%40example.com",
                occurrenceStart: start
            ),
            event: CalendarEvent(
                uid: "FAKE0001", title: "Weekly Sync", attendees: [], body: "",
                startDate: start, endDate: end
            ),
            sourceRevision: nil, detailsFetchedAt: nil,
            attendeeState: .notRequested, attendeeCount: 2
        )
    }

    static func envelopeJSON(payload: String) -> String {
        #"{"type":"result","subtype":"success","is_error":false,"num_turns":2,"duration_api_ms":100,"result":"x","structured_output":"#
        + payload + #","usage":{"input_tokens":10,"output_tokens":5}}"#
    }

    static func decodeList(_ payload: String) throws -> CalendarCLIResponseEnvelope {
        try JSONDecoder().decode(CalendarCLIResponseEnvelope.self, from: Data(payload.utf8))
    }

    static func decodeDetail(_ payload: String) throws -> CalendarCLIDetailEnvelope {
        try JSONDecoder().decode(CalendarCLIDetailEnvelope.self, from: Data(payload.utf8))
    }

    static func listPayload(
        requestID: UUID = listRequestID,
        mailbox: String = "ada.lovelace@example.com",
        windowStart: String = "2026-09-22T00:00:00Z",
        windowEnd: String = "2026-09-23T00:00:00Z",
        status: String = "complete",
        events: String = "[]",
        paginationComplete: Bool = true,
        totalResultCount: Int? = 0,
        error: String? = nil
    ) -> String {
        """
        {"v":1,"requestID":"\(requestID.uuidString)","status":"\(status)","mailbox":"\(mailbox)",\
        "windowStart":"\(windowStart)","windowEnd":"\(windowEnd)","events":\(events),\
        "paginationComplete":\(paginationComplete),"totalResultCount":\(totalResultCount.map(String.init) ?? "null"),\
        "error":\(error.map { "\"\($0)\"" } ?? "null")}
        """
    }

    static func eventJSON(
        uri: String = "calendar:///events/FAKE0001?owner=ada.lovelace%40example.com",
        id: String = "FAKE0001",
        title: String = "Weekly Sync",
        organizer: String? = "ada.lovelace@example.com",
        count: Int? = 2,
        start: String = "2026-09-22T07:15:00.0000000",
        end: String = "2026-09-22T07:45:00.0000000",
        cancelled: Bool = false,
        allDay: Bool = false,
        location: String? = "Team room",
        extra: String = ""
    ) -> String {
        """
        {"uri":"\(uri)","id":"\(id)","title":"\(title)",\
        "organizerEmail":\(organizer.map { "\"\($0)\"" } ?? "null"),\
        "attendeeCount":\(count.map(String.init) ?? "null"),"startUTC":"\(start)","endUTC":"\(end)",\
        "isCancelled":\(cancelled),"isAllDay":\(allDay),"location":\(location.map { "\"\($0)\"" } ?? "null")}\(extra)
        """
    }

    static func detailPayload(
        requestID: UUID = detailRequestID,
        uri: String = "calendar:///events/FAKE0001?owner=ada.lovelace%40example.com",
        start: String = "2026-09-22T07:15:00.0000000",
        end: String = "2026-09-22T07:45:00.0000000",
        state: String = "loaded",
        count: Int? = 1,
        revision: String? = nil,
        people: String = #"[{"name":"Ada Lovelace","email":"ada.lovelace@example.com"}]"#,
        status: String = "complete",
        error: String? = nil
    ) -> String {
        """
        {"v":1,"requestID":"\(requestID.uuidString)","status":"\(status)","uri":"\(uri)",\
        "startUTC":"\(start)","endUTC":"\(end)","attendeeState":"\(state)",\
        "attendeeCount":\(count.map(String.init) ?? "null"),\
        "revision":\(revision.map { "\"\($0)\"" } ?? "null"),"people":\(people),\
        "error":\(error.map { "\"\($0)\"" } ?? "null")}
        """
    }

    static func validateList(
        _ payload: String,
        requestID: UUID = listRequestID,
        window: CalendarCLIWindow = listWindow,
        config: CalendarCLIConfig = config
    ) throws -> CalendarCLIListResult {
        try CalendarCLIPrompt.validateList(Self.decodeList(payload), requestID: requestID, window: window, config: config)
    }

    static func validateDetail(
        _ payload: String,
        requestID: UUID = detailRequestID,
        entry: CalendarCLIEntry = detailEntry,
        cap: Int = 20
    ) throws -> CalendarCLIPrompt.DetailOutcome {
        try CalendarCLIPrompt.validateDetail(
            Self.decodeDetail(payload),
            requestID: requestID,
            expectedURI: entry.key.resourceURI,
            expectedStart: entry.event.startDate,
            expectedEnd: entry.event.endDate,
            cap: cap
        )
    }

    private static func invalidReason(of error: Error) -> CalendarCLITransportError.Reason? {
        guard case CalendarCLITransportError.invalidOutput(let reason) = error else { return nil }
        return reason
    }

    // MARK: - Fixture-driven contract

    @Test("Sanitized complete list fixture decodes to cache-ready entries")
    func completeListFixture() throws {
        let result = try CalendarCLIPrompt.listResult(
            from: try Self.fixture("cli-envelope-list.json"),
            requestID: Self.listRequestID,
            window: Self.listWindow,
            config: Self.config
        )
        #expect(result.completeness == .complete)
        #expect(result.entries.count == 2)
        let first = try #require(result.entries.first)
        #expect(first.event.title == "Weekly Sync")
        #expect(first.event.body.isEmpty) // invite bodies are never stored
        #expect(first.event.attendees.isEmpty) // rosters never load with the list
        #expect(first.attendeeCount == 2)
        #expect(first.attendeeState == .notRequested)
        #expect(first.key.mailbox == "ada.lovelace@example.com")
        #expect(first.key.resourceURI.hasPrefix("calendar:///events/"))
        #expect(first.event.organizer?.email == "ada.lovelace@example.com")
        let second = try #require(result.entries.last)
        #expect(second.attendeeCount == nil) // unknown count stays unknown
        #expect(second.event.location == nil)
    }

    @Test("Partial list fixture reports partial without completing pagination")
    func partialListFixture() throws {
        let envelope = try CalendarCLIPrompt.decodeCLIResultEnvelope(
            try Self.fixture("cli-envelope-list-partial.json"), as: CalendarCLIResponseEnvelope.self
        )
        let result = try CalendarCLIPrompt.validateList(
            #require(envelope.structuredOutput),
            requestID: Self.listRequestID, window: Self.listWindow, config: Self.config
        )
        #expect(result.completeness == .partial)
        #expect(result.message?.contains("Pagination") == true)
    }

    @Test("Blocked list fixture reports blocked access with no events")
    func blockedListFixture() throws {
        let envelope = try CalendarCLIPrompt.decodeCLIResultEnvelope(
            try Self.fixture("cli-envelope-list-blocked.json"), as: CalendarCLIResponseEnvelope.self
        )
        let result = try CalendarCLIPrompt.validateList(
            #require(envelope.structuredOutput),
            requestID: Self.listRequestID, window: Self.listWindow, config: Self.config
        )
        #expect(result.completeness == .blocked)
        #expect(result.entries.isEmpty)
        #expect(result.message?.contains("denied") == true)
    }

    @Test("Sanitized loaded roster fixture validates within the cap")
    func loadedDetailFixture() throws {
        let envelope = try CalendarCLIPrompt.decodeCLIResultEnvelope(
            try Self.fixture("cli-envelope-detail.json"), as: CalendarCLIDetailEnvelope.self
        )
        let outcome = try CalendarCLIPrompt.validateDetail(
            #require(envelope.structuredOutput),
            requestID: Self.detailRequestID,
            expectedURI: Self.detailEntry.key.resourceURI,
            expectedStart: Self.detailEntry.event.startDate,
            expectedEnd: Self.detailEntry.event.endDate,
            cap: 20
        )
        #expect(outcome.state == .loaded)
        #expect(outcome.completeness == .complete)
        #expect(outcome.people.count == 3)
        #expect(outcome.attendeeCount == 3)
        #expect(outcome.revision == "2026-09-21T16:40:12.0000000Z")
    }

    @Test("Omitted large meeting fixture omits the entire roster")
    func omittedDetailFixture() throws {
        let envelope = try CalendarCLIPrompt.decodeCLIResultEnvelope(
            try Self.fixture("cli-envelope-detail-omitted.json"), as: CalendarCLIDetailEnvelope.self
        )
        let outcome = try CalendarCLIPrompt.validateDetail(
            #require(envelope.structuredOutput),
            requestID: Self.detailRequestID,
            expectedURI: "calendar:///events/FAKE0003?owner=ada.lovelace%40example.com",
            expectedStart: Self.utcDate("2026-09-22T12:00:00.0000000"),
            expectedEnd: Self.utcDate("2026-09-22T13:00:00.0000000"),
            cap: 20
        )
        #expect(outcome.state == .omittedLargeMeeting)
        #expect(outcome.people.isEmpty)
        #expect(outcome.attendeeCount == 29)
        #expect(outcome.completeness == .complete)
    }

    @Test("Verified zero-attendee fixture yields none")
    func noneDetailFixture() throws {
        let envelope = try CalendarCLIPrompt.decodeCLIResultEnvelope(
            try Self.fixture("cli-envelope-detail-none.json"), as: CalendarCLIDetailEnvelope.self
        )
        let outcome = try CalendarCLIPrompt.validateDetail(
            #require(envelope.structuredOutput),
            requestID: Self.detailRequestID,
            expectedURI: "calendar:///events/FAKE0004?owner=ada.lovelace%40example.com",
            expectedStart: Self.utcDate("2026-09-22T11:00:00.0000000"),
            expectedEnd: Self.utcDate("2026-09-22T11:50:00.0000000"),
            cap: 20
        )
        #expect(outcome.state == .none)
        #expect(outcome.attendeeCount == 0)
        #expect(outcome.people.isEmpty)
    }

    @Test("Unavailable fixture never claims a roster")
    func unavailableDetailFixture() throws {
        let envelope = try CalendarCLIPrompt.decodeCLIResultEnvelope(
            try Self.fixture("cli-envelope-detail-unavailable.json"), as: CalendarCLIDetailEnvelope.self
        )
        let outcome = try CalendarCLIPrompt.validateDetail(
            #require(envelope.structuredOutput),
            requestID: Self.detailRequestID,
            expectedURI: "calendar:///events/FAKE0005?owner=ada.lovelace%40example.com",
            expectedStart: Self.utcDate("2026-09-22T14:00:00.0000000"),
            expectedEnd: Self.utcDate("2026-09-22T15:00:00.0000000"),
            cap: 20
        )
        #expect(outcome.state == .unavailable)
        #expect(outcome.completeness == .partial)
        #expect(outcome.people.isEmpty)
    }

    // MARK: - Envelope validation

    @Test("Prose or fenced model output is rejected, never scraped")
    func proseOutputRejected() throws {
        #expect(throws: CalendarCLITransportError.self) {
            _ = try CalendarCLIPrompt.decodeCLIResultEnvelope(
                try Self.fixture("haiku-prose-output.txt"), as: CalendarCLIResponseEnvelope.self
            )
        }
    }

    @Test("CLI-reported errors are rejected before payload inspection")
    func cliErrorEnvelopeRejected() throws {
        let raw = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}"#
        do {
            _ = try CalendarCLIPrompt.decodeCLIResultEnvelope(raw, as: CalendarCLIResponseEnvelope.self)
            Issue.record("Expected rejection")
        } catch {
            #expect(Self.invalidReason(of: error) == .cliReportedError)
        }
    }

    @Test("A success envelope without a structured payload is an incomplete generation")
    func missingPayloadRejected() throws {
        let raw = #"{"type":"result","subtype":"success","is_error":false,"result":"partial prose"}"#
        do {
            _ = try CalendarCLIPrompt.decodeCLIResultEnvelope(raw, as: CalendarCLIResponseEnvelope.self)
            Issue.record("Expected rejection")
        } catch {
            #expect(Self.invalidReason(of: error) == .missingStructuredOutput)
        }
    }

    @Test("Empty stdout is rejected")
    func emptyOutputRejected() {
        do {
            _ = try CalendarCLIPrompt.decodeCLIResultEnvelope("   \n  ", as: CalendarCLIResponseEnvelope.self)
            Issue.record("Expected rejection")
        } catch {
            #expect(Self.invalidReason(of: error) == .emptyOutput)
        }
    }

    // MARK: - Request identity validation

    @Test("Wrong request ID is rejected")
    func requestIDMismatchRejected() {
        do {
            _ = try Self.validateList(Self.listPayload(requestID: UUID()))
            Issue.record("Expected rejection")
        } catch {
            #expect(Self.invalidReason(of: error) == .requestIDMismatch)
        }
    }

    @Test("Wrong mailbox is rejected")
    func mailboxMismatchRejected() {
        do {
            _ = try Self.validateList(Self.listPayload(mailbox: "someone.else@example.com"))
            Issue.record("Expected rejection")
        } catch {
            #expect(Self.invalidReason(of: error) == .mailboxMismatch)
        }
    }

    @Test("Wrong window echo is rejected")
    func windowMismatchRejected() {
        do {
            _ = try Self.validateList(Self.listPayload(windowStart: "2026-09-25T00:00:00Z"))
            Issue.record("Expected rejection")
        } catch {
            #expect(Self.invalidReason(of: error) == .windowMismatch)
        }
    }

    @Test("Unparseable window echo is rejected")
    func unparseableWindowRejected() {
        do {
            _ = try Self.validateList(Self.listPayload(windowStart: "the twenty second of September"))
            Issue.record("Expected rejection")
        } catch {
            #expect(Self.invalidReason(of: error) == .windowMismatch)
        }
    }

    @Test("Unsupported payload version is rejected")
    func versionMismatchRejected() throws {
        let payload = #"{"v":2,"requestID":"11111111-1111-1111-1111-111111111111","status":"complete","mailbox":"ada.lovelace@example.com","windowStart":"2026-09-22T00:00:00Z","windowEnd":"2026-09-23T00:00:00Z","events":[],"paginationComplete":true,"totalResultCount":0,"error":null}"#
        do {
            _ = try Self.validateList(payload)
            Issue.record("Expected rejection")
        } catch {
            #expect(Self.invalidReason(of: error) == .unsupportedPayloadVersion)
        }
    }

    // MARK: - List event validation

    @Test("Complete empty result is a valid empty calendar")
    func emptyResultIsValid() throws {
        let result = try Self.validateList(Self.listPayload())
        #expect(result.completeness == .complete)
        #expect(result.entries.isEmpty)
        #expect(result.message == nil)
    }

    @Test("Malformed event dates degrade to partial and drop the event")
    func malformedDatesDegradeToPartial() throws {
        let events = Self.eventJSON(start: "not-a-date") + "," + Self.eventJSON(id: "FAKE0002", start: "2026-09-22T09:00:00.0000000", end: "2026-09-22T09:45:00.0000000")
        let result = try Self.validateList(Self.listPayload(events: "[\(events)]", totalResultCount: 1))
        #expect(result.completeness == .partial)
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.event.title == "Weekly Sync")
    }

    @Test("An event ending before it starts is dropped")
    func endBeforeStartDropped() throws {
        let events = Self.eventJSON(start: "2026-09-22T09:45:00.0000000", end: "2026-09-22T09:00:00.0000000")
        let result = try Self.validateList(Self.listPayload(events: "[\(events)]", totalResultCount: nil))
        #expect(result.completeness == .partial)
        #expect(result.entries.isEmpty)
    }

    @Test("Wrong URI schemes are dropped")
    func wrongURISchemeDropped() throws {
        let events = Self.eventJSON(uri: "https://calendar.example/event/1")
        let result = try Self.validateList(Self.listPayload(events: "[\(events)]", totalResultCount: nil))
        #expect(result.completeness == .partial)
        #expect(result.entries.isEmpty)
    }

    @Test("Events outside the requested window are dropped")
    func outsideWindowDropped() throws {
        let events = Self.eventJSON(start: "2026-09-25T09:00:00.0000000", end: "2026-09-25T10:00:00.0000000")
        let result = try Self.validateList(Self.listPayload(events: "[\(events)]", totalResultCount: nil))
        #expect(result.completeness == .partial)
        #expect(result.entries.isEmpty)
    }

    @Test("Overlapping pages deduplicate by id and start")
    func duplicatesDeduplicated() throws {
        let first = Self.eventJSON()
        let duplicate = Self.eventJSON(title: "Weekly Sync")
        let result = try Self.validateList(Self.listPayload(
            events: "[\(first),\(duplicate)]",
            totalResultCount: 1
        ))
        #expect(result.completeness == .complete)
        #expect(result.entries.count == 1)
    }

    @Test("Result count inconsistent with returned events is partial")
    func countMismatchIsPartial() throws {
        let events = Self.eventJSON()
        let result = try Self.validateList(Self.listPayload(events: "[\(events)]", totalResultCount: 3))
        #expect(result.completeness == .partial)
        #expect(result.entries.count == 1) // returned events stay usable
    }

    @Test("Incomplete pagination is partial")
    func incompletePaginationIsPartial() throws {
        let result = try Self.validateList(Self.listPayload(paginationComplete: false))
        #expect(result.completeness == .partial)
    }

    @Test("Negative attendee count degrades to partial")
    func negativeCountDropped() throws {
        let events = Self.eventJSON(count: -3)
        let result = try Self.validateList(Self.listPayload(events: "[\(events)]", totalResultCount: nil))
        #expect(result.completeness == .partial)
        #expect(result.entries.isEmpty)
    }

    @Test("Cancelled events keep their cancellation state")
    func cancelledStatePreserved() throws {
        let events = Self.eventJSON(cancelled: true)
        let result = try Self.validateList(Self.listPayload(events: "[\(events)]"))
        #expect(result.entries.first?.isCancelled == true)
    }

    // MARK: - Cap boundaries (cap = 20)

    @Test("Cap boundary: zero verified people is none")
    func capBoundaryZero() throws {
        let outcome = try Self.validateDetail(Self.detailPayload(state: "none", count: 0, people: "[]"))
        #expect(outcome.state == .none)
        #expect(outcome.completeness == .complete)
    }

    @Test("Cap boundary: exactly the cap loads a complete roster")
    func capBoundaryAtCap() throws {
        let people = (0..<20).map {
            #"{"name":"Person \#($0)","email":"person\#($0)@example.com"}"#
        }.joined(separator: ",")
        let outcome = try Self.validateDetail(Self.detailPayload(state: "loaded", count: 20, people: "[\(people)]"))
        #expect(outcome.state == .loaded)
        #expect(outcome.people.count == 20)
    }

    @Test("Cap boundary: over-cap people arrays are rejected outright")
    func capBoundaryOverCap() {
        let people = (0..<21).map {
            #"{"name":"Person \#($0)","email":"person\#($0)@example.com"}"#
        }.joined(separator: ",")
        do {
            _ = try Self.validateDetail(Self.detailPayload(state: "loaded", count: 21, people: "[\(people)]"))
            Issue.record("Expected rejection")
        } catch {
            #expect(Self.invalidReason(of: error) == .rosterExceedsCap)
        }
    }

    @Test("Loaded state with an inconsistent count degrades to unavailable")
    func loadedInconsistentCount() throws {
        let people = #"[{"name":"Ada Lovelace","email":"ada.lovelace@example.com"},{"name":"Grace Hopper","email":"grace.hopper@example.com"}]"#
        let outcome = try Self.validateDetail(Self.detailPayload(state: "loaded", count: 3, people: people))
        #expect(outcome.state == .unavailable)
        #expect(outcome.people.isEmpty)
    }

    @Test("Omitted state below the cap is unavailable, not omitted")
    func omittedBelowCapIsUnavailable() throws {
        let outcome = try Self.validateDetail(Self.detailPayload(state: "omittedLargeMeeting", count: 15, people: "[]"))
        #expect(outcome.state == .unavailable)
    }

    @Test("Omitted state with people is unavailable")
    func omittedWithPeopleIsUnavailable() throws {
        let outcome = try Self.validateDetail(Self.detailPayload(
            state: "omittedLargeMeeting",
            count: 25,
            people: #"[{"name":"Ada Lovelace","email":"ada.lovelace@example.com"}]"#
        ))
        #expect(outcome.state == .unavailable)
    }

    @Test("None state with a nonzero count is unavailable")
    func noneWithCountIsUnavailable() throws {
        let outcome = try Self.validateDetail(Self.detailPayload(state: "none", count: 2, people: "[]"))
        #expect(outcome.state == .unavailable)
    }

    // MARK: - Occurrence identity

    @Test("Mismatched occurrence times are rejected, never copied")
    func occurrenceIdentityMismatch() {
        do {
            _ = try Self.validateDetail(Self.detailPayload(
                uri: "calendar:///events/FAKE0001?owner=ada.lovelace%40example.com",
                start: "2026-09-22T08:15:00.0000000" // one hour off: another occurrence
            ))
            Issue.record("Expected rejection")
        } catch {
            #expect(Self.invalidReason(of: error) == .occurrenceIdentityMismatch)
        }
    }

    @Test("Response for a different URI is rejected")
    func differentURIRejected() {
        do {
            _ = try Self.validateDetail(Self.detailPayload(uri: "calendar:///events/OTHER?owner=ada.lovelace%40example.com"))
            Issue.record("Expected rejection")
        } catch {
            #expect(Self.invalidReason(of: error) == .occurrenceIdentityMismatch)
        }
    }

    // MARK: - Schema hygiene

    @Test("List schema never requests bodies or attendee arrays")
    func listSchemaExcludesSensitiveFields() {
        let schema = CalendarCLIPrompt.listJSONSchema
        #expect(!schema.contains("\"summary\""))
        #expect(!schema.contains("\"body\""))
        #expect(!schema.contains("\"agenda\""))
        #expect(!schema.contains("\"attendees\""))
        #expect(schema.contains("\"attendeeCount\""))
    }

    @Test("Detail schema bounds people by the configured cap")
    func detailSchemaCapsPeople() {
        #expect(CalendarCLIPrompt.detailJSONSchema(cap: 20).contains("\"maxItems\":20"))
        #expect(CalendarCLIPrompt.detailJSONSchema(cap: 1).contains("\"maxItems\":1"))
        let schema = CalendarCLIPrompt.detailJSONSchema(cap: 20)
        #expect(!schema.contains("\"body\""))
        #expect(!schema.contains("\"bodyPreview\""))
        #expect(!schema.contains("\"agenda\""))
    }

    // MARK: - Connector time parsing

    @Test("Connector UTC timestamps parse with up to seven fractional digits")
    func connectorTimeParsing() {
        #expect(CalendarCLITimeParsing.connectorUTCDate("2026-09-22T07:15:00.0000000") == Self.utcDate("2026-09-22T07:15:00Z"))
        #expect(CalendarCLITimeParsing.connectorUTCDate("2026-09-22T07:15:00Z") == Self.utcDate("2026-09-22T07:15:00Z"))
        #expect(CalendarCLITimeParsing.connectorUTCDate("2026-09-22T07:15:00.500") == Self.utcDate("2026-09-22T07:15:00.500Z"))
        #expect(CalendarCLITimeParsing.connectorUTCDate("2026-09-22T07:15:00.1234567890Z") == Self.utcDate("2026-09-22T07:15:00.123Z"))
        #expect(CalendarCLITimeParsing.connectorUTCDate("") == nil)
        #expect(CalendarCLITimeParsing.connectorUTCDate("garbage") == nil)
        #expect(CalendarCLITimeParsing.connectorUTCDate("2026-13-45T99:15:00") == nil)
    }
}
