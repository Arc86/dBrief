import Foundation
import Testing
@testable import dBrief

@Suite("System capture lifecycle") @MainActor
struct SystemCaptureLifecycleTests {
    @MainActor private final class Fixture {
        var calls: [String] = []
        var hold: String?
        var continuation: CheckedContinuation<Void, Never>?
        var ids: [UUID] = []
        func step(_ name: String) async {
            calls.append(name)
            if hold == name { await withCheckedContinuation { continuation = $0 } }
        }
        func release() { hold = nil; continuation?.resume(); continuation = nil }
        func make(_ id: UUID) async throws -> SystemCaptureLifecycle.Stream {
            ids.append(id)
            await step("make")
            return .init(id: id, start: { await self.step("start") }, stop: {
                await self.step("stop"); return nil
            })
        }
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test(arguments: ["make", "start"])
    func stopWaitsForStaleCreationAndCleanupWithoutInstallingStream(stage: String) async throws {
        let fixture = Fixture(); fixture.hold = stage
        let owner = SystemCaptureLifecycle()
        let start = owner.start(make: { try await fixture.make($0) })
        try await wait { fixture.continuation != nil }
        let stop = owner.stop()
        #expect(!owner.accepts(fixture.ids[0]))
        #expect(owner.isBusy)
        fixture.release()
        try await start.value
        await stop.value
        #expect(fixture.calls.filter { $0 == "stop" }.count == 1)
        #expect(fixture.calls.filter { $0 == "start" }.count == (stage == "make" ? 0 : 1))
        #expect(!owner.isBusy)
    }

    @Test(arguments: ["make", "start"])
    func stopWaitsForSuspendedStaleCleanup(stage: String) async throws {
        let fixture = Fixture(), owner = SystemCaptureLifecycle()
        fixture.hold = stage
        let start = owner.start(make: { try await fixture.make($0) })
        try await wait { fixture.continuation != nil }
        let stopped = owner.stop()
        var writerClosed = false
        let closeWriter = Task { await stopped.value; writerClosed = true }
        fixture.release()
        fixture.hold = "stop"
        try await wait { fixture.continuation != nil }
        #expect(!writerClosed && owner.isBusy)
        #expect(!owner.accepts(fixture.ids[0]))
        fixture.release()
        try await start.value; await closeWriter.value
        #expect(writerClosed && !owner.isBusy)
        #expect(fixture.calls.filter { $0 == "stop" }.count == 1)
    }

    @Test func resumeWaitsForOldStopAndStaleFailureCannotReachNewStream() async throws {
        let fixture = Fixture(), owner = SystemCaptureLifecycle()
        try await owner.start(make: { try await fixture.make($0) }).value
        let oldID = fixture.ids[0]
        fixture.hold = "stop"
        let pause = owner.stop()
        try await wait { fixture.continuation != nil }
        let resume = owner.start(make: { try await fixture.make($0) })
        #expect(!owner.accepts(oldID))
        #expect(fixture.ids.count == 1)
        fixture.release()
        await pause.value; try await resume.value
        #expect(fixture.calls == ["make", "start", "stop", "make", "start"])
        #expect(owner.accepts(fixture.ids[1]))
        owner.reportFailure(.init(error: CocoaError(.fileReadUnknown)), from: oldID)
        #expect(owner.lastFailure == nil)
        owner.reportFailure(.init(error: CocoaError(.fileReadUnknown)), from: fixture.ids[1])
        #expect(owner.lastFailure != nil)
        await owner.stop().value
    }

    @Test func queuedResumeThenStopSkipsCreationAndClosesOnlyOnce() async throws {
        let fixture = Fixture(), owner = SystemCaptureLifecycle()
        try await owner.start(make: { try await fixture.make($0) }).value
        fixture.hold = "stop"
        let pause = owner.stop()
        try await wait { fixture.continuation != nil }
        let resume = owner.start(make: { try await fixture.make($0) })
        let stop = owner.stop()
        fixture.release()
        await pause.value; try await resume.value; await stop.value
        #expect(fixture.calls == ["make", "start", "stop"])
        #expect(!owner.isBusy)
    }

    @Test func failedStartCleansPartialStreamAndNextAttemptCanRun() async throws {
        let fixture = Fixture(), owner = SystemCaptureLifecycle()
        let start = owner.start(make: { id in
            .init(id: id, start: { throw CocoaError(.fileReadUnknown) }, stop: {
                await fixture.step("failed-stop"); return nil
            })
        })
        await #expect(throws: CocoaError.self) { try await start.value }
        #expect(fixture.calls == ["failed-stop"])
        try await owner.start(make: { try await fixture.make($0) }).value
        #expect(owner.accepts(fixture.ids[0]))
        await owner.stop().value
    }

    @Test func retiredCallbacksCannotRunOrReplaceCurrentDebounce() async throws {
        let old = CaptureCallbackLifetime(), current = CaptureCallbackLifetime()
        var calls: [String] = []
        let oldCallback = old.handler { calls.append("old") }
        let currentCallback = current.handler { calls.append("current") }
        oldCallback()
        old.invalidate() // Already-enqueued callback must check at delivery.
        oldCallback()
        currentCallback()
        try await wait { calls == ["current"] }
        current.invalidate()
        currentCallback()
        await Task.yield()
        #expect(calls == ["current"])
    }
}
