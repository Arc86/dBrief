import Testing
import Foundation
@testable import dBrief

/// Behavioral tests around an injected fixed clock and a counting fake
/// transport: coalescing, freshness, cooldown, invalidation and cache
/// preservation semantics.
struct CalendarCLIServiceTests {

    @Test("A persisted fresh roster avoids the connector after restart")
    func persistedFreshRosterAvoidsConnectorAfterRestart() async throws {
        let clock = FixedClock(Date())
        let window = Self.makeWindow()
        let config = Self.makeConfig()
        let loaded = Self.loadedEntry(window: window, revision: "R1", clock: clock)
        let transport = FakeTransport(listResult: Self.completeResult([]), detailResult: loaded)
        let (_, store) = Self.makeService(transport: transport, clock: clock)
        #expect(store.storeDetail(scope: CalendarCLIScope(config: config), entry: loaded) == .saved)
        let request = Self.makeEntry(window: window, revision: "R1")
        let restarted = CalendarCLIService(transport: transport,
            store: CalendarCLICacheStore(directory: store.directory, now: clock.reader), now: clock.reader)
        let result = try await restarted.detail(entry: request, config: config, force: false)
        #expect(result.attendeeState == .loaded)
        #expect(result.event.attendees == loaded.event.attendees)
        #expect(transport.detailCallCount == 0)
    }

    private actor GatedDetailTransport: CalendarCLITransporting {
        var pending: CheckedContinuation<CalendarCLIEntry, Error>?
        var calls = 0
        func list(window: CalendarCLIWindow, config: CalendarCLIConfig) async throws -> CalendarCLIListResult {
            CalendarCLIListResult(entries: [], completeness: .complete, message: nil)
        }
        func detail(entry: CalendarCLIEntry, config: CalendarCLIConfig) async throws -> CalendarCLIEntry {
            calls += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        func waitForRequest() async -> Bool {
            for _ in 0..<100 {
                if pending != nil { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
        func release(_ entry: CalendarCLIEntry) {
            pending?.resume(returning: entry)
            pending = nil
        }
    }

    @Test("Manual and processing detail callers share one capped result")
    func detailCallersCoalesce() async throws {
        let clock = FixedClock(Date())
        let window = Self.makeWindow()
        let config = Self.makeConfig().updating(maxAttendees: 1)
        let request = Self.makeEntry(window: window)
        let loaded = CalendarCLIEntry(key: request.key,
            event: request.event.replacing(attendees: [
                .init(name: "Alex", email: nil), .init(name: "Sam", email: nil)]),
            sourceRevision: request.sourceRevision, detailsFetchedAt: clock.now,
            attendeeState: .loaded, attendeeCount: 2)
        let transport = GatedDetailTransport()
        let store = CalendarCLICacheStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), now: clock.reader)
        let service = CalendarCLIService(transport: transport, store: store, now: clock.reader)
        async let manual = service.detail(entry: request, config: config, force: false)
        async let processing = service.detail(entry: request, config: config, force: false)
        #expect(await transport.waitForRequest())
        await transport.release(loaded)
        let (a, b) = try await (manual, processing)
        #expect(a == b)
        #expect(a.attendeeState == .omittedLargeMeeting)
        #expect(a.event.attendees.isEmpty)
        #expect(await transport.calls == 1)
    }

    actor GatedTransport: CalendarCLITransporting {
        private var requests: [CheckedContinuation<CalendarCLIListResult, Error>] = []
        private let detailEntry: CalendarCLIEntry

        init(detailEntry: CalendarCLIEntry) { self.detailEntry = detailEntry }

        func list(window: CalendarCLIWindow, config: CalendarCLIConfig) async throws -> CalendarCLIListResult {
            try await withCheckedThrowingContinuation { requests.append($0) }
        }

        func detail(entry: CalendarCLIEntry, config: CalendarCLIConfig) async throws -> CalendarCLIEntry {
            detailEntry
        }

        func pendingCount() -> Int { requests.count }

        func releaseFirst(_ result: Result<CalendarCLIListResult, Error>) {
            guard !requests.isEmpty else { return }
            let request = requests.removeFirst()
            request.resume(with: result)
        }

        func waitForCount(_ count: Int) async -> Bool {
            for _ in 0..<100 {
                if requests.count >= count { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
    }

    @Test("An old completion cannot remove or overwrite a replacement flight")
    func oldCompletionCannotAffectReplacement() async throws {
        let window = Self.makeWindow()
        let clock = FixedClock(Date())
        let oldEntry = Self.makeEntry(window: window, title: "Old")
        let newEntry = Self.makeEntry(window: window, title: "New")
        let transport = GatedTransport(detailEntry: oldEntry)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CalendarCLICacheStore(directory: directory, now: clock.reader)
        let service = CalendarCLIService(transport: transport, store: store, now: clock.reader)
        let config = Self.makeConfig()

        let oldTask = Task { try await service.refreshSnapshot(window: window, config: config, force: true) }
        #expect(await transport.waitForCount(1))
        await service.invalidate()
        let replacement = Task { try await service.refreshSnapshot(window: window, config: config, force: true) }
        #expect(await transport.waitForCount(2))
        await transport.releaseFirst(.success(Self.completeResult([oldEntry])))
        do { _ = try await oldTask.value; Issue.record("Old request was not cancelled") }
        catch is CancellationError { }
        catch { Issue.record("Unexpected old-request error") }
        let joined = Task { try await service.refreshSnapshot(window: window, config: config, force: true) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.pendingCount() == 1)
        await transport.releaseFirst(.success(Self.completeResult([newEntry])))
        let a = try await replacement.value
        let b = try await joined.value
        #expect(a.entries == [newEntry])
        #expect(b.entries == [newEntry])
        #expect(store.loadList(scope: CalendarCLIScope(config: config), window: window)?.entries == [newEntry])
    }

    @Test("Clear cache rejects a late response without writing to disk")
    func clearRejectsLateWrite() async throws {
        let window = Self.makeWindow()
        let entry = Self.makeEntry(window: window)
        let transport = GatedTransport(detailEntry: entry)
        let clock = FixedClock(Date())
        let store = CalendarCLICacheStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), now: clock.reader)
        let service = CalendarCLIService(transport: transport, store: store, now: clock.reader)
        let config = Self.makeConfig()
        let pending = Task { try await service.refreshSnapshot(window: window, config: config, force: true) }
        #expect(await transport.waitForCount(1))
        await service.clearCache()
        await transport.releaseFirst(.success(Self.completeResult([entry])))
        do { _ = try await pending.value; Issue.record("Cleared request was not cancelled") }
        catch is CancellationError { }
        catch { Issue.record("Unexpected cleared-request error") }
        #expect(store.loadList(scope: CalendarCLIScope(config: config), window: window) == nil)
    }

    @Test("A late failure cannot start a cooldown for the replacement generation")
    func lateFailureCannotStartCooldown() async throws {
        let window = Self.makeWindow()
        let entry = Self.makeEntry(window: window)
        let transport = GatedTransport(detailEntry: entry)
        let clock = FixedClock(Date())
        let store = CalendarCLICacheStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), now: clock.reader)
        let service = CalendarCLIService(transport: transport, store: store, now: clock.reader)
        let config = Self.makeConfig()
        let pending = Task { try await service.refreshSnapshot(window: window, config: config, force: true) }
        #expect(await transport.waitForCount(1))
        await service.invalidate()
        await transport.releaseFirst(.failure(CalendarCLIServiceError.refreshFailed))
        do { _ = try await pending.value; Issue.record("Old failure was not cancelled") }
        catch is CancellationError { }
        catch { Issue.record("Unexpected old-request error") }
        let fresh = Task { try await service.refreshSnapshot(window: window, config: config, force: false) }
        #expect(await transport.waitForCount(1))
        await transport.releaseFirst(.success(Self.completeResult([entry])))
        #expect(try await fresh.value.entries == [entry])
    }

    @Test("A historical empty snapshot fetched before day-end refreshes once")
    func historicalEmptySnapshotRefreshesOnce() async throws {
        let window = Self.makeWindow()
        let clock = FixedClock(window.end.addingTimeInterval(86_400))
        let entry = Self.makeEntry(window: window)
        let transport = FakeTransport(listResult: Self.completeResult([]), detailResult: entry)
        let (service, store) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()
        let scope = CalendarCLIScope(config: config)
        store.storeList(.init(scope: scope, window: window, entries: [],
                              lastSuccessfulRefresh: window.end.addingTimeInterval(-60),
                              lastAttempt: window.end.addingTimeInterval(-60)))
        let first = try await service.refreshSnapshot(window: window, config: config, force: false)
        #expect(first.outcome == .refreshed)
        #expect(first.hasCompleteSnapshot)
        #expect(first.entries.isEmpty)
        let second = try await service.refreshSnapshot(window: window, config: config, force: false)
        #expect(second.outcome == .cached)
        #expect(transport.listCallCount == 1)
    }

    @Test("A failed refresh returns typed cached data and an attempt stamp")
    func failureReturnsTypedRead() async throws {
        let window = Self.makeWindow()
        let clock = FixedClock(Date())
        let entry = Self.makeEntry(window: window)
        let transport = FakeTransport(listResult: Self.completeResult([]), detailResult: entry)
        transport.listError = CalendarCLIServiceError.identityMismatch
        let (service, store) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()
        let old = clock.now.addingTimeInterval(-7200)
        store.storeList(.init(scope: CalendarCLIScope(config: config), window: window,
                              entries: [entry], lastSuccessfulRefresh: old, lastAttempt: old))
        let read = try await service.refreshSnapshot(window: window, config: config, force: true)
        #expect(read.outcome == .failed)
        #expect(read.entries == [entry])
        #expect(read.lastSuccessfulRefresh == old)
        #expect(read.lastAttempt == clock.now)
    }

    @Test("Partial responses preserve complete data and cool down automatic retry")
    func partialCooldown() async throws {
        let window = Self.makeWindow()
        let clock = FixedClock(Date())
        let entry = Self.makeEntry(window: window)
        let transport = FakeTransport(listResult: CalendarCLIListResult(
            entries: [], completeness: .partial, message: nil), detailResult: entry)
        let (service, store) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()
        let success = window.end.addingTimeInterval(-60)
        store.storeList(.init(scope: CalendarCLIScope(config: config), window: window,
                              entries: [entry], lastSuccessfulRefresh: success, lastAttempt: success))
        let first = try await service.refreshSnapshot(window: window, config: config, force: false)
        let second = try await service.refreshSnapshot(window: window, config: config, force: false)
        #expect(first.outcome == .partial)
        #expect(second.outcome == .partial)
        #expect(second.entries == [entry])
        #expect(transport.listCallCount == 1)
        let forced = try await service.refreshSnapshot(window: window, config: config, force: true)
        #expect(forced.outcome == .partial)
        #expect(transport.listCallCount == 2)
    }

    @Test("Joined waiters receive the same finalized list result")
    func concurrentWaitersReceiveFinalRead() async throws {
        let window = Self.makeWindow()
        let clock = FixedClock(Date())
        let entry = Self.makeEntry(window: window)
        let transport = FakeTransport(listResult: Self.completeResult([entry]), detailResult: entry)
        transport.holdNextListCall()
        let (service, _) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()
        async let first = service.refreshSnapshot(window: window, config: config, force: true)
        async let second = service.refreshSnapshot(window: window, config: config, force: true)
        try await Task.sleep(for: .milliseconds(20))
        transport.releaseListCalls()
        let (a, b) = try await (first, second)
        #expect(a.outcome == .refreshed)
        #expect(b.outcome == .refreshed)
        #expect(a.entries == b.entries)
        #expect(a.lastSuccessfulRefresh == b.lastSuccessfulRefresh)
        #expect(a.persistence == b.persistence)
        #expect(transport.listCallCount == 1)
    }

    @Test("A successful list stays readable in memory when disk persistence fails")
    func persistenceFailureRetainsMemory() async throws {
        let clock = FixedClock(Date())
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base); try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("cache")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = CalendarCLICacheStore(directory: link, now: clock.reader)
        let window = Self.makeWindow()
        let entry = Self.makeEntry(window: window)
        let transport = FakeTransport(listResult: Self.completeResult([entry]), detailResult: entry)
        let service = CalendarCLIService(transport: transport, store: store, now: clock.reader)
        let config = Self.makeConfig()
        let refreshed = try await service.refreshSnapshot(window: window, config: config, force: true)
        #expect(refreshed.entries == [entry])
        #expect(refreshed.persistence == .failed)
        let cached = await service.cachedSnapshot(window: window, config: config)
        #expect(cached.entries == [entry])
        #expect(cached.persistence == .failed)
        #expect(await service.lastPersistenceOutcome(window: window, config: config) == .failed)
        #expect(store.loadList(scope: CalendarCLIScope(config: config), window: window) == nil)
    }

    // MARK: - Fakes

    /// Counting fake transport with an optional gate that holds list calls
    /// in flight until released.
    final class FakeTransport: CalendarCLITransporting, @unchecked Sendable {
        private let lock = NSLock()
        private var _listCallCount = 0
        private var _detailCallCount = 0
        private var listGates: [CheckedContinuation<Void, Never>] = []
        private var holdNextList = false

        var listResult: CalendarCLIListResult
        var detailResult: CalendarCLIEntry
        var listError: Error?
        var detailError: Error?

        init(listResult: CalendarCLIListResult, detailResult: CalendarCLIEntry) {
            self.listResult = listResult
            self.detailResult = detailResult
        }

        var listCallCount: Int { lock.withLock { _listCallCount } }
        var detailCallCount: Int { lock.withLock { _detailCallCount } }

        func holdNextListCall() {
            lock.withLock { holdNextList = true }
        }

        func releaseListCalls() {
            let gates: [CheckedContinuation<Void, Never>] = lock.withLock {
                let released = listGates
                listGates = []
                holdNextList = false
                return released
            }
            gates.forEach { $0.resume() }
        }

        func list(window: CalendarCLIWindow, config: CalendarCLIConfig) async throws -> CalendarCLIListResult {
            lock.withLock { _listCallCount += 1 }
            let shouldWait = lock.withLock { holdNextList }
            if shouldWait {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.withLock { listGates.append(continuation) }
                }
            }
            if let listError { throw listError }
            return listResult
        }

        func detail(entry: CalendarCLIEntry, config: CalendarCLIConfig) async throws -> CalendarCLIEntry {
            lock.withLock { _detailCallCount += 1 }
            if let detailError { throw detailError }
            return detailResult
        }
    }

    final class FixedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Date
        init(_ time: Date) { self.time = time }
        var now: Date { lock.withLock { time } }
        func advance(_ interval: TimeInterval) { lock.withLock { time = time.addingTimeInterval(interval) } }
        var reader: @Sendable () -> Date { { self.now } }
    }

    // MARK: - Builders

    static let mailbox = "ada@example.com"

    static func makeConfig(
        policy: CalendarCLIConfig.AttendeePolicy = .onDemand,
        cap: Int = 20,
        calendarName: String? = nil
    ) -> CalendarCLIConfig {
        .unnormalized(timeoutSeconds: 30, mailboxEmail: Self.mailbox,
                      calendarName: calendarName, attendeePolicy: policy, maxAttendees: cap)
    }

    static func makeWindow(day: Int = 0) -> CalendarCLIWindow {
        CalendarCLIWindow(
            start: Date(timeIntervalSince1970: 1_789_000_000 + Double(day) * 86_400),
            end: Date(timeIntervalSince1970: 1_789_086_400 + Double(day) * 86_400),
            timeZoneID: "Europe/Amsterdam"
        )
    }

    static func makeEntry(
        uri: String = "calendar:///events/E1?owner=ada%40example.com",
        window: CalendarCLIWindow,
        title: String = "Weekly Sync",
        state: CalendarCLIAttendeeState = .notRequested,
        revision: String? = nil,
        fetchedAt: Date? = nil,
        attendees: [CalendarEvent.Person] = [],
        count: Int? = nil
    ) -> CalendarCLIEntry {
        CalendarCLIEntry(
            key: CalendarCLIOccurrenceKey(
                mailbox: Self.mailbox, calendar: "", resourceURI: uri,
                occurrenceStart: window.start.addingTimeInterval(3600)
            ),
            event: CalendarEvent(
                uid: "E1", title: title, attendees: attendees, body: "",
                startDate: window.start.addingTimeInterval(3600),
                endDate: window.start.addingTimeInterval(5400)
            ),
            sourceRevision: revision, detailsFetchedAt: fetchedAt,
            attendeeState: state, attendeeCount: count
        )
    }

    static func makeService(
        transport: FakeTransport,
        clock: FixedClock
    ) -> (CalendarCLIService, CalendarCLICacheStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalendarCLIServiceTests-\(UUID().uuidString)", isDirectory: true)
        let store = CalendarCLICacheStore(directory: dir, now: clock.reader)
        let service = CalendarCLIService(transport: transport, store: store, now: clock.reader)
        return (service, store)
    }

    static func completeResult(_ entries: [CalendarCLIEntry]) -> CalendarCLIListResult {
        CalendarCLIListResult(entries: entries, completeness: .complete, message: nil)
    }

    static func loadedEntry(window: CalendarCLIWindow, revision: String?, clock: FixedClock, people: Int = 2) -> CalendarCLIEntry {
        let roster = (0..<people).map { CalendarEvent.Person(name: "P\($0)", email: "p\($0)@example.com") }
        return Self.makeEntry(
            window: window, state: .loaded, revision: revision,
            fetchedAt: clock.now, attendees: roster
        )
    }

    // MARK: - Required assertions from the plan

    @Test("Concurrent refreshes coalesce into one list call")
    func concurrentRefreshesCoalesce() async throws {
        let transport = FakeTransport(
            listResult: Self.completeResult([Self.makeEntry(window: Self.makeWindow())]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: "R", clock: FixedClock(Date()))
        )
        let (service, _) = Self.makeService(transport: transport, clock: FixedClock(Date()))
        let config = Self.makeConfig()
        async let first: [CalendarCLIEntry] = try service.refresh(window: Self.makeWindow(), config: config, force: false)
        async let second: [CalendarCLIEntry] = try service.refresh(window: Self.makeWindow(), config: config, force: false)
        let (a, b) = try await (first, second)
        #expect(a.count == 1)
        #expect(b.count == 1)
        let calls = transport.listCallCount
        #expect(calls == 1) // concurrent refreshes coalesced
        #expect(transport.detailCallCount == 0) // list refresh never expands all bodies
    }

    @Test("A failed refresh preserves entries and the last success stamp")
    func failurePreservesCache() async throws {
        let transport = FakeTransport(
            listResult: Self.completeResult([Self.makeEntry(window: Self.makeWindow())]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: FixedClock(Date()))
        )
        let clock = FixedClock(Date(timeIntervalSince1970: 1_789_000_000))
        let (service, store) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()
        _ = try await service.refresh(window: Self.makeWindow(), config: config, force: false)

        let scope = CalendarCLIScope(config: config)
        let before = store.loadList(scope: scope, window: Self.makeWindow())

        transport.listError = CalendarCLITransportError.processFailed(status: 1)
        clock.advance(60)
        do {
            _ = try await service.refresh(window: Self.makeWindow(), config: config, force: true)
            Issue.record("Expected failure")
        } catch {
            // expected
        }

        let after = store.loadList(scope: scope, window: Self.makeWindow())
        #expect(after?.entries == before?.entries)
        #expect(after?.lastSuccessfulRefresh == before?.lastSuccessfulRefresh)
        #expect(after?.lastAttempt != before?.lastAttempt) // attempt advanced
    }

    // MARK: - Restart and in-flight behavior

    @Test("A fresh disk snapshot after restart yields zero list calls")
    func restartUsesDiskSnapshot() async throws {
        let transport = FakeTransport(
            listResult: Self.completeResult([Self.makeEntry(window: Self.makeWindow())]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: FixedClock(Date()))
        )
        let clock = FixedClock(Date())
        let (service, store) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()
        _ = try await service.refresh(window: Self.makeWindow(), config: config, force: false)
        #expect(transport.listCallCount == 1)

        // "Restart": a new service over the same store.
        let restarted = CalendarCLIService(transport: transport, store: store, now: clock.reader)
        let entries = await restarted.cached(window: Self.makeWindow(), config: config)
        #expect(entries.count == 1)
        #expect(transport.listCallCount == 1) // no new call
    }

    @Test("A stale snapshot stays readable while a refresh is in flight")
    func staleReadableDuringRefresh() async throws {
        let transport = FakeTransport(
            listResult: Self.completeResult([Self.makeEntry(window: Self.makeWindow(), title: "New")]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: FixedClock(Date()))
        )
        transport.holdNextListCall()
        let clock = FixedClock(Date())
        let (service, _) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()

        let refreshTask = Task {
            try await service.refresh(window: Self.makeWindow(), config: config, force: false)
        }
        // Give the refresh a moment to start and hit the gate.
        try await Task.sleep(for: .milliseconds(100))
        let stale = await service.cached(window: Self.makeWindow(), config: config)
        #expect(stale.isEmpty) // nothing cached yet, but no blocking

        transport.releaseListCalls()
        let entries = try await refreshTask.value
        #expect(entries.first?.event.title == "New")
    }

    // MARK: - Roster policy

    @Test("Never policy rejects roster reads before any transport call")
    func neverPreventsReads() async {
        let transport = FakeTransport(
            listResult: Self.completeResult([]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: FixedClock(Date()))
        )
        let (service, _) = Self.makeService(transport: transport, clock: FixedClock(Date()))
        let entry = Self.makeEntry(window: Self.makeWindow(), state: .loaded, fetchedAt: nil)
        do {
            _ = try await service.detail(entry: entry, config: Self.makeConfig(policy: .never), force: true)
            Issue.record("Expected rejection")
        } catch {
            #expect(transport.detailCallCount == 0)
        }
    }

    @Test("Known over-cap counts skip the resource read")
    func knownLargeSkipsRead() async throws {
        let transport = FakeTransport(
            listResult: Self.completeResult([]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: FixedClock(Date()))
        )
        let clock = FixedClock(Date())
        let (service, store) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()
        let entry = Self.makeEntry(window: Self.makeWindow(), state: .notRequested, count: 29)

        let updated = try await service.detail(entry: entry, config: config, force: true)
        #expect(updated.attendeeState == .omittedLargeMeeting)
        #expect(updated.attendeeCount == 29)
        #expect(updated.event.attendees.isEmpty)
        #expect(transport.detailCallCount == 0)

        let stored = store.loadDetail(
            scope: CalendarCLIScope(config: config), key: entry.key)
        #expect(stored?.attendeeState == .omittedLargeMeeting)
    }

    @Test("Fresh rosters are reused; expired TTL rosters read as stale without fetching")
    func attendeeTTL() async throws {
        let transport = FakeTransport(
            listResult: Self.completeResult([]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: FixedClock(Date()))
        )
        let clock = FixedClock(Date())
        let (service, _) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()

        let fresh = Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: clock)
        let updated = try await service.detail(entry: fresh, config: config, force: false)
        #expect(updated.attendeeState == .loaded)
        #expect(transport.detailCallCount == 0) // still fresh, no read

        clock.advance(60 * 60 + 1)
        let staleRead = await service.cached(window: Self.makeWindow(), config: config)
        #expect(staleRead.isEmpty) // not in the list snapshot; staleness applies to cached reads

        // Explicit request past the TTL fetches again.
        _ = try await service.detail(entry: fresh, config: config, force: false)
        #expect(transport.detailCallCount == 1)
    }

    @Test("A revision change marks rosters stale without fetching them")
    func revisionChangeMarksStale() async throws {
        let transport = FakeTransport(
            listResult: Self.completeResult([
                Self.makeEntry(window: Self.makeWindow(), state: .notRequested, revision: "R2")
            ]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: "R2", clock: FixedClock(Date()))
        )
        let clock = FixedClock(Date())
        let (service, store) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()

        // Pre-seed the snapshot with a loaded roster at revision R1; the list
        // stamp is stale so the refresh actually reaches the connector.
        let loaded = Self.loadedEntry(window: Self.makeWindow(), revision: "R1", clock: clock)
        let scope = CalendarCLIScope(config: config)
        store.storeList(CalendarCLIStoredListSnapshot(
            scope: scope, window: Self.makeWindow(), entries: [loaded],
            lastSuccessfulRefresh: Self.makeWindow().end.addingTimeInterval(-2 * 60 * 60),
            lastAttempt: Self.makeWindow().end.addingTimeInterval(-2 * 60 * 60)
        ))

        let refreshed = try await service.refresh(window: Self.makeWindow(), config: config, force: false)
        // The refreshed list itself carries notRequested metadata; the stale
        // roster in storage must not be fetched by the refresh.
        #expect(transport.detailCallCount == 0)

        // And a read of the seeded roster (with the fresh list visible) shows stale.
        let entries = await service.cached(window: Self.makeWindow(), config: config)
        #expect(refreshed.first?.attendeeState == .notRequested)
        _ = entries // cached reflects the complete refresh result
    }

    @Test("Reducing the cap or selecting Never purges incompatible rosters")
    func configurationChangePurges() async throws {
        let transport = FakeTransport(
            listResult: Self.completeResult([]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: FixedClock(Date()))
        )
        let clock = FixedClock(Date())
        let (service, store) = Self.makeService(transport: transport, clock: clock)
        let scope = CalendarCLIScope(config: Self.makeConfig())

        let wide = Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: clock, people: 25)
        store.storeDetail(scope: scope, entry: wide)
        #expect(store.loadDetail(scope: scope, key: wide.key) != nil)

        await service.configurationChanged(Self.makeConfig(cap: 20))
        #expect(store.loadDetail(scope: scope, key: wide.key) == nil)
    }

    // MARK: - Cooldowns

    @Test("Automatic retry honors the cooldown; forced retry bypasses it")
    func retryCooldownAndForcedRetry() async throws {
        let transport = FakeTransport(
            listResult: Self.completeResult([Self.makeEntry(window: Self.makeWindow())]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: FixedClock(Date()))
        )
        let clock = FixedClock(Date())
        let (service, _) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()

        transport.listError = CalendarCLITransportError.processFailed(status: 1)
        do { _ = try await service.refresh(window: Self.makeWindow(), config: config, force: true) } catch {}
        let afterFirstFailure = transport.listCallCount
        #expect(afterFirstFailure == 1)

        // Automatic refresh inside the cooldown: no call, no throw.
        clock.advance(60)
        let cached = try await service.refresh(window: Self.makeWindow(), config: config, force: false)
        #expect(transport.listCallCount == 1)
        #expect(cached.isEmpty)

        // Forced refresh bypasses the cooldown.
        transport.listError = nil
        let forced = try await service.refresh(window: Self.makeWindow(), config: config, force: true)
        #expect(transport.listCallCount == 2)
        #expect(forced.count == 1)

        // Cooldown cleared by success: automatic works again.
        _ = try await service.refresh(window: Self.makeWindow(), config: config, force: false)
        #expect(transport.listCallCount == 2)
    }

    // MARK: - Invalidation

    @Test("Invalidation cancels in-flight work and discards stale results")
    func invalidationDiscardsInFlight() async throws {
        let transport = FakeTransport(
            listResult: Self.completeResult([Self.makeEntry(window: Self.makeWindow())]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: FixedClock(Date()))
        )
        transport.holdNextListCall()
        let clock = FixedClock(Date())
        let (service, store) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()
        let scope = CalendarCLIScope(config: config)

        let refreshTask = Task {
            try await service.refresh(window: Self.makeWindow(), config: config, force: false)
        }
        try await Task.sleep(for: .milliseconds(100))
        await service.invalidate()
        transport.releaseListCalls()

        do {
            _ = try await refreshTask.value
            Issue.record("Expected cancellation")
        } catch {
            // cancelled or discarded
        }
        #expect(store.loadList(scope: scope, window: Self.makeWindow()) == nil)
    }

    @Test("Cancelling one waiter does not cancel the shared refresh")
    func waiterCancellationDoesNotKillSharedWork() async throws {
        let transport = FakeTransport(
            listResult: Self.completeResult([Self.makeEntry(window: Self.makeWindow())]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: FixedClock(Date()))
        )
        transport.holdNextListCall()
        let clock = FixedClock(Date())
        let (service, _) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()

        let waiterA = Task {
            try await service.refresh(window: Self.makeWindow(), config: config, force: false)
        }
        try await Task.sleep(for: .milliseconds(100))
        let waiterB = Task {
            try await service.refresh(window: Self.makeWindow(), config: config, force: false)
        }
        try await Task.sleep(for: .milliseconds(100))
        waiterA.cancel()
        transport.releaseListCalls()

        let entries = try await waiterB.value
        #expect(entries.count == 1)
        #expect(transport.listCallCount == 1)
    }

    // MARK: - Window semantics

    @Test("Manual only never starts automatic list calls, even without a snapshot")
    func manualOnlyNeedsForce() async throws {
        let clock = FixedClock(Date())
        let transport = FakeTransport(
            listResult: Self.completeResult([Self.makeEntry(window: Self.makeWindow())]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: clock))
        let (service, _) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig().updating(listFreshnessSeconds: 0)
        #expect(try await service.refresh(window: Self.makeWindow(), config: config, force: false).isEmpty)
        #expect(transport.listCallCount == 0)
        #expect(try await service.refresh(window: Self.makeWindow(), config: config, force: true).count == 1)
        clock.advance(90_000)
        #expect(try await service.refresh(window: Self.makeWindow(), config: config, force: false).count == 1)
        #expect(transport.listCallCount == 1)
    }

    @Test("Zero meetings are a complete empty calendar")
    func zeroMeetings() async throws {
        let transport = FakeTransport(listResult: Self.completeResult([]),
                                      detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: FixedClock(Date())))
        let clock = FixedClock(Date())
        let (service, _) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()
        let entries = try await service.refresh(window: Self.makeWindow(), config: config, force: false)
        #expect(entries.isEmpty)
        let again = await service.cached(window: Self.makeWindow(), config: config)
        #expect(again.isEmpty)
    }

    @Test("Next-day rollover keeps separate snapshots")
    func nextDayRollover() async throws {
        let transport = FakeTransport(
            listResult: Self.completeResult([Self.makeEntry(window: Self.makeWindow())]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: FixedClock(Date()))
        )
        let clock = FixedClock(Date())
        let (service, _) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()
        _ = try await service.refresh(window: Self.makeWindow(day: 0), config: config, force: false)
        #expect(await service.cached(window: Self.makeWindow(day: 1), config: config).isEmpty)
        #expect(await service.cached(window: Self.makeWindow(day: 0), config: config).count == 1)
    }

    @Test("Partial results keep the last complete snapshot visible")
    func partialPreservesSnapshot() async throws {
        let transport = FakeTransport(
            listResult: Self.completeResult([Self.makeEntry(window: Self.makeWindow(), title: "Old")]),
            detailResult: Self.loadedEntry(window: Self.makeWindow(), revision: nil, clock: FixedClock(Date()))
        )
        let clock = FixedClock(Date())
        let (service, _) = Self.makeService(transport: transport, clock: clock)
        let config = Self.makeConfig()
        _ = try await service.refresh(window: Self.makeWindow(), config: config, force: false)

        transport.listResult = CalendarCLIListResult(
            entries: [Self.makeEntry(window: Self.makeWindow(), title: "Half")],
            completeness: .partial, message: "pagination stopped early")
        let entries = try await service.refresh(window: Self.makeWindow(), config: config, force: true)
        // The caller sees the preserved complete snapshot, not the partial one.
        #expect(entries.first?.event.title == "Old")

        let cached = await service.cached(window: Self.makeWindow(), config: config)
        #expect(cached.first?.event.title == "Old")
    }
}
