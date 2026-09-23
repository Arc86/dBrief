import Foundation
import Testing
@testable import dBrief

/// Lifecycle coverage for the Claude CLI calendar source on RecordingManager:
/// selection routing, explicit attendee enrichment, late-completion guards,
/// historical linking and overnight/duplicate handling.
@Suite(.serialized)
@MainActor
struct CalendarCLILifecycleTests {

    // MARK: - Harness

    @MainActor
    final class Harness {
        let settings: AppSettings
        let state: AppState
        let manager: RecordingManager
        let transport: LifecycleTransport
        let clock: FixedClock
        let storeDirectory: URL
        private let oldSource: CalendarSource
        private let oldConfig: CalendarCLIConfig

        init() {
            settings = AppSettings()
            state = AppState()
            oldSource = settings.calendarSource
            oldConfig = settings.calendarCLIConfig
            settings.calendarSource = .claudeCLI
            settings.calendarCLIConfig = .unnormalized(
                timeoutSeconds: 30, mailboxEmail: "ada@example.com")

            transport = LifecycleTransport()
            clock = FixedClock(Date(timeIntervalSince1970: 1_789_000_000))
            storeDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CalendarCLILifecycle-\(UUID().uuidString)", isDirectory: true)
            let store = CalendarCLICacheStore(directory: storeDirectory)
            let service = CalendarCLIService(transport: transport, store: store, now: clock.reader)
            manager = RecordingManager(
                appState: state, appSettings: settings,
                transcriptStore: TranscriptStore(), insightsStore: InsightsStore(),
                voiceLibraryStore: VoiceLibraryStore(url: storeDirectory.appendingPathComponent("voices.json")),
                modelPerformanceStore: ModelPerformanceStore(url: storeDirectory.appendingPathComponent("performance.json")),
                processingJobStore: ProcessingJobStore(rootURL: storeDirectory.appendingPathComponent("jobs")),
                microsoftAuthService: MicrosoftAuthService(),
                calendarCLIService: service
            )
        }

        func cleanup() {
            settings.calendarSource = oldSource
            settings.calendarCLIConfig = oldConfig
            try? FileManager.default.removeItem(at: storeDirectory)
        }

        func recording(start: Date? = nil, duration: TimeInterval = 1800) -> Recording {
            Recording(
                date: start ?? Date(timeIntervalSince1970: 1_789_000_000 + 3600),
                fileURL: URL(fileURLWithPath: "/tmp/lifecycle-test.m4a"),
                duration: duration, meetingTitleDraft: "meeting"
            )
        }
    }

    /// Counting transport with independent list/detail gates.
    final class LifecycleTransport: CalendarCLITransporting, @unchecked Sendable {
        private let lock = NSLock()
        private var _listCalls = 0
        private var _detailCalls = 0
        private var listGates: [CheckedContinuation<Void, Never>] = []
        private var detailGates: [CheckedContinuation<Void, Never>] = []
        private var holdList = false
        private var holdDetail = false

        var listResult: CalendarCLIListResult
        var detailResult: CalendarCLIEntry
        var listError: Error?
        var detailError: Error?

        init() {
            listResult = CalendarCLIListResult(entries: [], completeness: .complete, message: nil)
            let start = Date(timeIntervalSince1970: 1_789_000_000 + 3600)
            detailResult = CalendarCLIEntry(
                key: CalendarCLIOccurrenceKey(mailbox: "ada@example.com", calendar: "",
                                              resourceURI: "calendar:///events/E1?owner=ada%40example.com",
                                              occurrenceStart: start),
                event: CalendarEvent(uid: "E1", title: "Weekly Sync",
                                     attendees: [CalendarEvent.Person(name: "Ada", email: "ada@example.com")],
                                     body: "", startDate: start, endDate: start.addingTimeInterval(1800)),
                sourceRevision: "R1", detailsFetchedAt: Date(),
                attendeeState: .loaded, attendeeCount: 1
            )
        }

        var listCalls: Int { lock.withLock { _listCalls } }
        var detailCalls: Int { lock.withLock { _detailCalls } }

        func holdNextList() { lock.withLock { holdList = true } }
        func holdNextDetail() { lock.withLock { holdDetail = true } }
        func releaseAll() {
            let (lists, details): ([CheckedContinuation<Void, Never>], [CheckedContinuation<Void, Never>]) = lock.withLock {
                let l = listGates
                let d = detailGates
                listGates = []
                detailGates = []
                holdList = false
                holdDetail = false
                return (l, d)
            }
            lists.forEach { $0.resume() }
            details.forEach { $0.resume() }
        }

        func list(window: CalendarCLIWindow, config: CalendarCLIConfig) async throws -> CalendarCLIListResult {
            lock.withLock { _listCalls += 1 }
            if lock.withLock({ holdList }) {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    lock.withLock { listGates.append(c) }
                }
            }
            if let listError { throw listError }
            return listResult
        }

        func detail(entry: CalendarCLIEntry, config: CalendarCLIConfig) async throws -> CalendarCLIEntry {
            lock.withLock { _detailCalls += 1 }
            if lock.withLock({ holdDetail }) {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    lock.withLock { detailGates.append(c) }
                }
            }
            if let detailError { throw detailError }
            return detailResult
        }
    }

    final class FixedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Date
        init(_ time: Date) { self.time = time }
        var now: Date { lock.withLock { time } }
        var reader: @Sendable () -> Date { { self.now } }
    }

    // MARK: - Helpers

    @MainActor
    private static func seedCandidate(
        _ harness: Harness,
        uri: String = "calendar:///events/E1?owner=ada%40example.com",
        title: String = "Weekly Sync",
        count: Int? = nil,
        state: CalendarCLIAttendeeState = .notRequested
    ) -> (Recording, CalendarEvent, CalendarCLIEntry) {
        let start = Date(timeIntervalSince1970: 1_789_000_000 + 3600)
        let entry = CalendarCLIEntry(
            key: CalendarCLIOccurrenceKey(
                mailbox: "ada@example.com", calendar: "", resourceURI: uri, occurrenceStart: start),
            event: CalendarEvent(uid: "E1", title: title, attendees: [], body: "",
                                 startDate: start, endDate: start.addingTimeInterval(1800)),
            sourceRevision: nil, detailsFetchedAt: nil,
            attendeeState: state, attendeeCount: count
        )
        let recording = harness.recording()
        harness.manager.calendarCLIEntryByEventID[entry.event.id] = entry
        recording.calendarEvent = entry.event
        recording.calendarCandidates = [entry.event]
        return (recording, entry.event, entry)
    }

    // MARK: - No unsolicited reads

    @Test("Picker loads a recording day on demand and refreshes it without changing the selection")
    func pickerRefresh() async {
        let harness = Harness()
        defer { harness.cleanup() }
        let recording = harness.recording()
        let start = recording.date
        let entry = CalendarCLIEntry(
            key: CalendarCLIOccurrenceKey(mailbox: "ada@example.com", calendar: "",
                                          resourceURI: "calendar:///events/E1?owner=ada%40example.com",
                                          occurrenceStart: start),
            event: CalendarEvent(uid: "E1", title: "New meeting", attendees: [], body: "",
                                 startDate: start, endDate: start.addingTimeInterval(1800)),
            sourceRevision: nil, detailsFetchedAt: nil,
            attendeeState: .notRequested, attendeeCount: 2)
        harness.transport.listResult = CalendarCLIListResult(entries: [entry], completeness: .complete, message: nil)
        let first = await harness.manager.refreshCalendarCLIPicker(for: recording, force: false)
        #expect(first == .complete)
        #expect(recording.calendarCandidates.map(\.title) == ["New meeting"])
        #expect(harness.transport.listCalls == 1)
        #expect(harness.transport.detailCalls == 0)

        harness.manager.selectCalendarCandidate(entry.event, for: recording)
        let second = await harness.manager.refreshCalendarCLIPicker(for: recording, force: true)
        #expect(second == .complete)
        #expect(recording.calendarEvent?.title == "New meeting")
        #expect(harness.transport.listCalls == 2)
        #expect(harness.transport.detailCalls == 0)

        harness.transport.listResult = CalendarCLIListResult(entries: [], completeness: .complete, message: nil)
        let removed = await harness.manager.refreshCalendarCLIPicker(for: recording, force: true)
        #expect(removed == .selectionMissing)
        #expect(recording.calendarEvent?.title == "New meeting")
        #expect(recording.calendarCandidates.map(\.title) == ["New meeting"])
    }

    @Test("Refreshing the recording day does not mark a next-day selection as removed")
    func nextDaySelectionSurvivesDayRefresh() async {
        let harness = Harness()
        defer { harness.cleanup() }
        let recording = harness.recording()
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: recording.date)!
        let event = CalendarEvent(uid: "NEXT", title: "Overnight follow-up", attendees: [], body: "",
                                  startDate: nextDay, endDate: nextDay.addingTimeInterval(1800))
        recording.calendarEvent = event
        recording.calendarCandidates = [event]
        let result = await harness.manager.refreshCalendarCLIPicker(for: recording, force: true)
        #expect(result == .complete)
        #expect(recording.calendarEvent?.id == event.id)
        #expect(recording.calendarCandidates.map(\.id) == [event.id])
    }

    @Test("Settings refresh reports partial and blocked connector results")
    func settingsRefreshReportsIncompleteResults() async {
        let harness = Harness()
        defer { harness.cleanup() }
        harness.transport.listResult = CalendarCLIListResult(
            entries: [], completeness: .partial, message: "Pagination stopped")
        #expect(await harness.manager.refreshCalendarCLINow() == .reachable(events: 0, partial: true))
        harness.transport.listResult = CalendarCLIListResult(
            entries: [], completeness: .blocked, message: "Permission denied")
        #expect(await harness.manager.refreshCalendarCLINow() == .blocked)
    }

    @MainActor
    @Test("List lookup and selection never fetch rosters or resources")
    func noUnsolicitedResourceReads() async {
        let harness = Harness()
        defer { harness.cleanup() }
        let start = Date(timeIntervalSince1970: 1_789_000_000 + 3600)
        harness.transport.listResult = CalendarCLIListResult(
            entries: [CalendarCLIEntry(
                key: CalendarCLIOccurrenceKey(mailbox: "ada@example.com", calendar: "",
                                              resourceURI: "calendar:///events/E1?owner=ada%40example.com",
                                              occurrenceStart: start),
                event: CalendarEvent(uid: "E1", title: "Weekly Sync", attendees: [], body: "",
                                     startDate: start, endDate: start.addingTimeInterval(1800)),
                sourceRevision: nil, detailsFetchedAt: nil,
                attendeeState: .notRequested, attendeeCount: 4
            )],
            completeness: .complete, message: nil)

        let recording = harness.recording()
        let events = await harness.manager.calendarCLIEvents(
            recordingStart: recording.date, recordingEnd: recording.date.addingTimeInterval(recording.duration))
        #expect(events.count == 1)
        #expect(harness.transport.listCalls == 1)
        #expect(harness.transport.detailCalls == 0) // list never expands bodies

        harness.manager.selectCalendarCandidate(events.first, for: recording)
        #expect(recording.calendarEvent?.id == events.first?.id)
        #expect(recording.calendarSelectionRevision == 1)
        #expect(harness.transport.detailCalls == 0) // selection fetches nothing
    }

    @MainActor
    @Test("A known over-cap meeting skips the resource read")
    func knownLargeSkip() async {
        let harness = Harness()
        defer { harness.cleanup() }
        let (recording, _, _) = Self.seedCandidate(
            harness, count: 29, state: .omittedLargeMeeting)

        let outcome = await harness.manager.loadCalendarCLIAttendees(for: recording)
        #expect(outcome == .omittedLargeMeeting(count: 29))
        #expect(harness.transport.detailCalls == 0)
    }

    @MainActor
    @Test("An unknown count still performs the explicitly requested read")
    func unknownCountFetchesOnRequest() async {
        let harness = Harness()
        defer { harness.cleanup() }
        let (recording, _, _) = Self.seedCandidate(harness, count: nil)
        let outcome = await harness.manager.loadCalendarCLIAttendees(for: recording)
        #expect(outcome == .loaded(1))
        #expect(harness.transport.detailCalls == 1)
    }

    @MainActor
    @Test("Never policy blocks the attendee action before any read")
    func neverPolicyBlocksAction() async {
        let harness = Harness()
        defer { harness.cleanup() }
        harness.settings.calendarCLIConfig = .unnormalized(
            timeoutSeconds: 30, mailboxEmail: "ada@example.com",
            attendeePolicy: .never, maxAttendees: 20)
        let (recording, _, _) = Self.seedCandidate(harness)
        let outcome = await harness.manager.loadCalendarCLIAttendees(for: recording)
        #expect(outcome == .policyForbids)
        #expect(harness.transport.detailCalls == 0)
    }

    @MainActor
    @Test("A failed attendee load leaves the recording unchanged")
    func failedAttendeeLoad() async {
        let harness = Harness()
        defer { harness.cleanup() }
        let (recording, event, _) = Self.seedCandidate(harness)
        harness.transport.detailError = CalendarCLITransportError.processFailed(status: 1)
        let outcome = await harness.manager.loadCalendarCLIAttendees(for: recording)
        #expect(outcome == .failed)
        #expect(recording.calendarEvent?.id == event.id)
        #expect(recording.calendarEvent?.attendees.isEmpty == true)
    }

    @MainActor
    @Test("Manual selection during an in-flight attendee load discards the completion")
    func selectionChangeDiscardsLateCompletion() async {
        let harness = Harness()
        defer { harness.cleanup() }
        let (recording, eventA, _) = Self.seedCandidate(harness)

        // A second candidate B for the switch.
        let startB = Date(timeIntervalSince1970: 1_789_000_000 + 7200)
        let eventB = CalendarEvent(uid: "E2", title: "Other", attendees: [], body: "",
                                   startDate: startB, endDate: startB.addingTimeInterval(1800))
        let keyB = CalendarCLIOccurrenceKey(mailbox: "ada@example.com", calendar: "",
                                            resourceURI: "calendar:///events/E2?owner=ada%40example.com",
                                            occurrenceStart: startB)
        let entryB = CalendarCLIEntry(key: keyB, event: eventB, sourceRevision: nil,
                                      detailsFetchedAt: nil, attendeeState: .notRequested,
                                      attendeeCount: 2)
        recording.calendarCandidates = [eventA, eventB]
        harness.manager.calendarCLIEntryByEventID[eventB.id] = entryB

        harness.transport.holdNextDetail()
        let loadTask = Task { await harness.manager.loadCalendarCLIAttendees(for: recording) }
        try? await Task.sleep(for: .milliseconds(100))

        // A-to-B manual switch while A's detail runs.
        harness.manager.selectCalendarCandidate(eventB, for: recording)

        harness.transport.releaseAll()
        let outcome = await loadTask.value
        #expect(outcome == .discarded)
        #expect(recording.calendarEvent?.id == eventB.id) // B selection intact
        #expect(recording.calendarCandidates.contains(where: { $0.id == eventB.id }))
    }

    @MainActor
    @Test("Changing mailbox during attendee load discards the old account response")
    func mailboxChangeDiscardsLateCompletion() async {
        let harness = Harness()
        defer { harness.cleanup() }
        let (recording, oldEvent, _) = Self.seedCandidate(harness)
        harness.transport.holdNextDetail()
        let task = Task { await harness.manager.loadCalendarCLIAttendees(for: recording) }
        try? await Task.sleep(for: .milliseconds(100))
        harness.settings.calendarCLIConfig = harness.settings.calendarCLIConfig.updating(mailboxEmail: "other@example.com")
        harness.transport.releaseAll()
        #expect(await task.value == .discarded)
        #expect(recording.calendarEvent?.id == oldEvent.id)
    }

    @MainActor
    @Test("Manual participant edits survive a roster load")
    func userEditsPreserved() async {
        let harness = Harness()
        defer { harness.cleanup() }
        let (recording, _, _) = Self.seedCandidate(harness)
        recording.participants = ["My Manual Name"]

        let outcome = await harness.manager.loadCalendarCLIAttendees(for: recording)
        #expect(outcome == .loaded(1))
        #expect(recording.participants == ["My Manual Name"])
        #expect(recording.calendarEvent?.attendeeNames == ["Ada"])
    }

    @MainActor
    @Test("Auto-filled participants refresh on a roster load")
    func autoFilledParticipantsRefresh() async {
        let harness = Harness()
        defer { harness.cleanup() }
        let (recording, _, _) = Self.seedCandidate(harness)
        // Field still holds the pre-load state (empty here): roster applies.
        let outcome = await harness.manager.loadCalendarCLIAttendees(for: recording)
        #expect(outcome == .loaded(1))
        #expect(recording.participants == ["Ada"])
    }

    // MARK: - Windows and dedupe

    @Test("Overnight recordings cover both intersecting days and deduplicate")
    func overnightRecordingDedupe() async {
        let harness = Harness()
        defer { harness.cleanup() }
        // Recording 23:40 → 00:20 across local midnight.
        let local = Calendar.current
        var night = DateComponents()
        night.year = 2026; night.month = 9; night.day = 22
        night.hour = 23; night.minute = 40
        let start = local.date(from: night).unsafelyUnwrapped
        let end = start.addingTimeInterval(40 * 60)
        harness.transport.listResult = CalendarCLIListResult(
            entries: [CalendarCLIEntry(
                key: CalendarCLIOccurrenceKey(mailbox: "ada@example.com", calendar: "",
                                              resourceURI: "calendar:///events/E1?owner=ada%40example.com",
                                              occurrenceStart: start.addingTimeInterval(-60)),
                event: CalendarEvent(uid: "E1", title: "Late session", attendees: [], body: "",
                                     startDate: start.addingTimeInterval(-60),
                                     endDate: start.addingTimeInterval(60)),
                sourceRevision: nil, detailsFetchedAt: nil,
                attendeeState: .notRequested, attendeeCount: nil
            )],
            completeness: .complete, message: nil)

        let manager = harness.manager
        let events = await manager.calendarCLIEvents(recordingStart: start, recordingEnd: end)
        #expect(harness.transport.listCalls == 2) // both days queried
        #expect(events.count == 1) // duplicate occurrence deduplicated
    }

    @Test("Day windows respect the match window and never use naive arithmetic")
    func dayWindowBoundaries() {
        // Local-calendar boundaries: a 15-minute match window before midnight
        // pulls in the preceding day as a second window.
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 22
        components.hour = 0; components.minute = 10
        let justAfterMidnight = calendar.date(from: components).unsafelyUnwrapped
        let windows = RecordingManager.calendarCLIDayWindows(
            from: justAfterMidnight, to: justAfterMidnight.addingTimeInterval(600),
            matchWindow: 15 * 60, calendar: calendar)
        #expect(windows.count == 2)
        let zones = Set(windows.map(\.timeZoneID))
        #expect(zones == [calendar.timeZone.identifier])
        for window in windows {
            #expect(window.end > window.start)
        }
    }

    // MARK: - Historical linking

    @MainActor
    @Test("Historical linking fetches the original day metadata only")
    func historicalLinkingFetchesOriginalDay() async {
        let harness = Harness()
        defer { harness.cleanup() }
        let oldStart = Date(timeIntervalSince1970: 1_700_000_000) // years back
        let end = oldStart.addingTimeInterval(1800)
        harness.transport.listResult = CalendarCLIListResult(
            entries: [CalendarCLIEntry(
                key: CalendarCLIOccurrenceKey(mailbox: "ada@example.com", calendar: "",
                                              resourceURI: "calendar:///events/OLD?owner=ada%40example.com",
                                              occurrenceStart: oldStart),
                event: CalendarEvent(uid: "OLD", title: "Old meeting", attendees: [], body: "",
                                     startDate: oldStart, endDate: end),
                sourceRevision: nil, detailsFetchedAt: nil,
                attendeeState: .notRequested, attendeeCount: 3
            )],
            completeness: .complete, message: nil)

        let manager = harness.manager
        let events = await manager.calendarCLIEvents(recordingStart: oldStart, recordingEnd: end)
        #expect(harness.transport.listCalls == 1) // the original day only
        #expect(harness.transport.detailCalls == 0) // metadata only
        #expect(events.first?.title == "Old meeting")
    }

    @MainActor
    @Test("Clearing the cache never erases metadata already attached to a recording")
    func clearCacheKeepsRecordingMetadata() async {
        let harness = Harness()
        defer { harness.cleanup() }
        let (recording, event, _) = Self.seedCandidate(harness)
        harness.manager.clearCalendarCLICache()
        #expect(recording.calendarEvent?.id == event.id)
    }

    // MARK: - Cancellation

    @MainActor
    @Test("A cancelled lookup leaves the recording with usable (empty) candidates")
    func cancelledLookupIsSafe() async throws {
        let harness = Harness()
        defer { harness.cleanup() }
        harness.transport.holdNextList()
        let recording = harness.recording()
        let manager = harness.manager
        let task = Task {
            await manager.calendarCLIEvents(
                recordingStart: recording.date,
                recordingEnd: recording.date.addingTimeInterval(recording.duration))
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        harness.transport.releaseAll()
        let events = await task.value
        #expect(events.isEmpty)
        #expect(recording.calendarCandidates.isEmpty)
    }
}
