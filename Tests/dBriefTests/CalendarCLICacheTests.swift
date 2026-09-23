import Testing
import Foundation
@testable import dBrief

/// Disk behavior of the calendar CLI cache: atomic persistence, restart
/// survival, retention, corruption and scope isolation.
struct CalendarCLICacheTests {

    static func makeStore() -> CalendarCLICacheStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalendarCLICacheTests-\(UUID().uuidString)", isDirectory: true)
        return CalendarCLICacheStore(directory: dir)
    }

    static var scope: CalendarCLIScope {
        CalendarCLIScope(mailbox: "ada@example.com", calendar: "", timeZoneID: "Europe/Amsterdam")
    }

    static var window: CalendarCLIWindow {
        CalendarCLIWindow(
            start: CalendarCLITimeParsing.connectorUTCDate("2026-09-22T00:00:00Z").unsafelyUnwrapped,
            end: CalendarCLITimeParsing.connectorUTCDate("2026-09-23T00:00:00Z").unsafelyUnwrapped,
            timeZoneID: "Europe/Amsterdam"
        )
    }

    static func entry(
        uri: String = "calendar:///events/E1?owner=ada%40example.com",
        start: Date = Date(timeIntervalSince1970: 1_789_000_000),
        state: CalendarCLIAttendeeState = .notRequested,
        revision: String? = nil,
        fetchedAt: Date? = nil,
        attendees: [CalendarEvent.Person] = []
    ) -> CalendarCLIEntry {
        CalendarCLIEntry(
            key: CalendarCLIOccurrenceKey(
                mailbox: "ada@example.com", calendar: "", resourceURI: uri, occurrenceStart: start
            ),
            event: CalendarEvent(
                uid: "E1", title: "Weekly Sync", attendees: attendees, body: "",
                startDate: start, endDate: start.addingTimeInterval(1800)
            ),
            sourceRevision: revision, detailsFetchedAt: fetchedAt,
            attendeeState: state, attendeeCount: attendees.isEmpty ? nil : attendees.count
        )
    }

    @Test("Snapshot roundtrips entries and both timestamps")
    func snapshotRoundtrip() {
        let store = Self.makeStore()
        let fetched = Date(timeIntervalSince1970: 1_789_100_000)
        var entry = Self.entry()
        entry = CalendarCLIEntry(
            key: entry.key, event: entry.event, sourceRevision: "R1",
            detailsFetchedAt: fetched, attendeeState: .loaded,
            attendeeCount: 2, isCancelled: false
        )
        let snapshot = CalendarCLIStoredListSnapshot(
            scope: Self.scope, window: Self.window, entries: [entry],
            lastSuccessfulRefresh: fetched, lastAttempt: fetched
        )
        store.storeList(snapshot)

        let loaded = store.loadList(scope: Self.scope, window: Self.window)
        #expect(loaded?.entries == snapshot.entries)
        #expect(loaded?.lastSuccessfulRefresh == fetched)
        #expect(loaded?.lastAttempt == fetched)
        #expect(loaded?.version == CalendarCLIStoredListSnapshot.currentVersion)
    }

    @Test("Corrupt snapshot is a visible cache miss, not an empty success")
    func corruptSnapshotIsMiss() throws {
        let store = Self.makeStore()
        let url = store.listFileURL(scope: Self.scope, window: Self.window)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{{{ not json".utf8).write(to: url)
        #expect(store.loadList(scope: Self.scope, window: Self.window) == nil)
    }

    @Test("Unsupported version is a cache miss")
    func unsupportedVersionIsMiss() throws {
        let store = Self.makeStore()
        let url = store.listFileURL(scope: Self.scope, window: Self.window)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = #"{"version":99,"scope":{"mailbox":"a","calendar":"","timeZoneID":"UTC"},"window":{"start":0,"end":1,"timeZoneID":"UTC"},"entries":[]}"#
        try Data(legacy.utf8).write(to: url)
        #expect(store.loadList(scope: Self.scope, window: Self.window) == nil)
    }

    @Test("Roster files survive a restart and omitted states persist")
    func rosterSurvivesRestart() {
        let store = Self.makeStore()
        let fetched = Date(timeIntervalSince1970: 1_789_100_000)
        let omitted = CalendarCLIEntry(
            key: Self.entry().key, event: Self.entry().event, sourceRevision: nil,
            detailsFetchedAt: fetched, attendeeState: .omittedLargeMeeting,
            attendeeCount: 40, isCancelled: false
        )
        store.storeDetail(scope: Self.scope, entry: omitted)

        // A brand-new store instance over the same directory is the restart.
        let restarted = CalendarCLICacheStore(directory: store.directory)
        let loaded = restarted.loadDetail(scope: Self.scope, key: omitted.key)
        #expect(loaded?.attendeeState == .omittedLargeMeeting)
        #expect(loaded?.attendeeCount == 40)
        #expect(loaded?.event.attendees.isEmpty == true)
    }

    @Test("Different calendars and time zones never share files")
    func scopeIsolation() {
        let store = Self.makeStore()
        let a = CalendarCLIScope(mailbox: "ada@example.com", calendar: "Work", timeZoneID: "UTC")
        let b = CalendarCLIScope(mailbox: "ada@example.com", calendar: "Private", timeZoneID: "UTC")
        #expect(a.digest != b.digest)
        #expect(a != b)
        let snapshot = CalendarCLIStoredListSnapshot(
            scope: a, window: Self.window, entries: [Self.entry()],
            lastSuccessfulRefresh: Date(), lastAttempt: Date()
        )
        store.storeList(snapshot)
        #expect(store.loadList(scope: b, window: Self.window) == nil)
        #expect(store.loadList(scope: a, window: Self.window) != nil)
    }

    @Test("Attempt updates preserve entries and the success stamp")
    func attemptUpdatePreservesSnapshot() {
        let store = Self.makeStore()
        let success = Date(timeIntervalSince1970: 1_789_100_000)
        store.storeList(CalendarCLIStoredListSnapshot(
            scope: Self.scope, window: Self.window, entries: [Self.entry()],
            lastSuccessfulRefresh: success, lastAttempt: success
        ))
        let attempted = success.addingTimeInterval(600)
        store.updateListAttempt(scope: Self.scope, window: Self.window, date: attempted)

        let loaded = store.loadList(scope: Self.scope, window: Self.window)
        #expect(loaded?.lastSuccessfulRefresh == success)
        #expect(loaded?.lastAttempt == attempted)
        #expect(loaded?.entries.count == 1)
    }

    @Test("Attempt update on a missing snapshot is a no-op")
    func attemptUpdateWithoutSnapshotIsNoop() {
        let store = Self.makeStore()
        store.updateListAttempt(scope: Self.scope, window: Self.window, date: Date())
        #expect(store.loadList(scope: Self.scope, window: Self.window) == nil)
    }

    @Test("Purging rosters drops loaded people over the cap and everything under Never")
    func rosterPurgeRules() {
        let store = Self.makeStore()
        let people = (0..<25).map {
            CalendarEvent.Person(name: "P\($0)", email: "p\($0)@example.com")
        }
        let fetched = Date()
        let big = CalendarCLIEntry(
            key: Self.entry().key, event: Self.entry().event.replacing(attendees: people),
            sourceRevision: nil, detailsFetchedAt: fetched,
            attendeeState: .loaded, attendeeCount: 25
        )
        let smallTemplate = Self.entry(
            uri: "calendar:///events/E2?owner=ada%40example.com",
            start: big.key.occurrenceStart.addingTimeInterval(3600)
        )
        let small = CalendarCLIEntry(
            key: smallTemplate.key,
            event: smallTemplate.event.replacing(attendees: Array(people.prefix(5))),
            sourceRevision: nil, detailsFetchedAt: fetched,
            attendeeState: .loaded, attendeeCount: 5
        )
        store.storeDetail(scope: Self.scope, entry: big)
        store.storeDetail(scope: Self.scope, entry: small)

        // Lowering the cap to 20 purges the 25-person roster, keeps the 5-person one.
        store.purgeRosters(scope: Self.scope, policy: .onDemand, cap: 20)
        #expect(store.loadDetail(scope: Self.scope, key: big.key) == nil)
        #expect(store.loadDetail(scope: Self.scope, key: small.key) != nil)

        // Selecting Never purges the rest.
        store.purgeRosters(scope: Self.scope, policy: .never, cap: 20)
        #expect(store.loadDetail(scope: Self.scope, key: small.key) == nil)
    }

    @Test("Retention keeps at most the configured snapshot count")
    func listRetentionLimit() {
        let store = Self.makeStore()
        let base = Self.window
        for day in 0..<(CalendarCLICacheStore.maxListSnapshots + 4) {
            let window = CalendarCLIWindow(
                start: base.start.addingTimeInterval(Double(day) * 86_400),
                end: base.end.addingTimeInterval(Double(day) * 86_400),
                timeZoneID: base.timeZoneID
            )
            store.storeList(CalendarCLIStoredListSnapshot(
                scope: Self.scope, window: window, entries: [],
                lastSuccessfulRefresh: Date(), lastAttempt: Date()
            ))
        }
        var remaining = 0
        for day in 0..<(CalendarCLICacheStore.maxListSnapshots + 4) {
            let window = CalendarCLIWindow(
                start: base.start.addingTimeInterval(Double(day) * 86_400),
                end: base.end.addingTimeInterval(Double(day) * 86_400),
                timeZoneID: base.timeZoneID
            )
            if store.loadList(scope: Self.scope, window: window) != nil { remaining += 1 }
        }
        #expect(remaining == CalendarCLICacheStore.maxListSnapshots)
    }

    @Test("DST-short and DST-long windows roundtrip exactly")
    func dstWindows() {
        let store = Self.makeStore()
        // Europe/Amsterdam: 2026-03-29 springs forward (23 h), 2026-10-25 falls back (25 h).
        let spring = CalendarCLIWindow(
            start: CalendarCLITimeParsing.connectorUTCDate("2026-03-28T23:00:00Z").unsafelyUnwrapped,
            end: CalendarCLITimeParsing.connectorUTCDate("2026-03-29T22:00:00Z").unsafelyUnwrapped,
            timeZoneID: "Europe/Amsterdam"
        )
        let autumn = CalendarCLIWindow(
            start: CalendarCLITimeParsing.connectorUTCDate("2026-10-24T22:00:00Z").unsafelyUnwrapped,
            end: CalendarCLITimeParsing.connectorUTCDate("2026-10-25T23:00:00Z").unsafelyUnwrapped,
            timeZoneID: "Europe/Amsterdam"
        )
        #expect(spring.end.timeIntervalSince(spring.start) == 23 * 3600)
        #expect(autumn.end.timeIntervalSince(autumn.start) == 25 * 3600)
        for window in [spring, autumn] {
            let snapshot = CalendarCLIStoredListSnapshot(
                scope: Self.scope, window: window, entries: [],
                lastSuccessfulRefresh: Date(), lastAttempt: Date()
            )
            store.storeList(snapshot)
            let loaded = store.loadList(scope: Self.scope, window: window)
            #expect(loaded?.window == window)
        }
    }

    @Test("Clear cache removes everything")
    func clearCache() {
        let store = Self.makeStore()
        store.storeList(CalendarCLIStoredListSnapshot(
            scope: Self.scope, window: Self.window, entries: [Self.entry()],
            lastSuccessfulRefresh: Date(), lastAttempt: Date()
        ))
        store.storeDetail(scope: Self.scope, entry: Self.entry(state: .loaded, fetchedAt: Date()))
        store.purgeAll()
        #expect(store.loadList(scope: Self.scope, window: Self.window) == nil)
        #expect(store.loadDetail(scope: Self.scope, key: Self.entry().key) == nil)
    }
}
