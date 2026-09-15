import Foundation
import Testing
import dBriefWire
@testable import dBriefMLHost

actor LifetimeSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@Suite struct ModelLifetimeTests {
    @Test func cancelledWorkDoesNotEnterModelOperation() async throws {
        let mutex = AsyncMutex()
        let started = LifetimeSignal(), release = LifetimeSignal(), attempted = LifetimeSignal()
        let owner = Task {
            try await mutex.withLock {
                await started.signal()
                await release.wait()
            }
        }
        await started.wait()
        let queued = Task {
            await attempted.signal()
            return try await mutex.withLock { true }
        }
        await attempted.wait()
        queued.cancel()
        await release.signal()
        try await owner.value
        do {
            _ = try await queued.value
            Issue.record("Cancelled request entered the model operation")
        } catch is CancellationError {
            // A cancelled queued request must never load a model.
        }
        let subsequent = try await mutex.withLock { 42 }
        #expect(subsequent == 42)
    }
}

actor LifetimeEvents {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

extension ModelLifetimeTests {
    @Test(arguments: [false, true])
    func cleanupWaitsForOperationAndCoalescesWarnings(failOperation: Bool) async throws {
        let mutex = AsyncMutex()
        let started = LifetimeSignal(), release = LifetimeSignal()
        let events = LifetimeEvents()
        let owner = Task {
            try await mutex.withLock {
                await events.append("inference started")
                await started.signal()
                await release.wait()
                await events.append("inference ended")
                if failOperation { throw CancellationError() }
            }
        }
        await started.wait()
        let cleanup = await mutex.enqueueCleanup { await events.append("unloaded") }
        let duplicate = await mutex.enqueueCleanup { await events.append("duplicate unload") }
        await release.signal()
        _ = await owner.result
        await cleanup.value
        await duplicate.value
        #expect(await events.values == ["inference started", "inference ended", "unloaded"])
        // A new warning after completion must still be able to release idle models.
        let later = await mutex.enqueueCleanup { await events.append("later unload") }
        await later.value
        #expect(await events.values.last == "later unload")
    }
}

actor ShutdownProbe {
    let started = LifetimeSignal(), cancellation = LifetimeSignal(), release = LifetimeSignal()
    private(set) var events: [String] = []
    func infer() async throws {
        events.append("started")
        await started.signal()
        await withTaskCancellationHandler {
            await release.wait()
        } onCancel: {
            Task { await self.cancellation.signal() }
        }
        events.append(Task.isCancelled ? "cancelled and drained" : "ended")
        try Task.checkCancellation()
    }
    func unload() { events.append("unloaded") }
}

extension ModelLifetimeTests {
    @Test(arguments: [false, true], [false, true])
    func shutdownDrainsCancelledRequestsBeforeUnloadingAndRejectsNewWork(explicitRequest: Bool, cancelFirst: Bool) async {
        let probe = ShutdownProbe()
        let backend = MockBackend(lifetimeProbe: probe)
        let loop = RequestLoop(backend: backend, writer: StdoutWriter(.nullDevice))
        let id = UUID()
        #expect(loop.submit(.init(id: id, request: .transcribe(path: "/synthetic.wav", initialPrompt: nil,
                                                             config: .default, safeMode: false, unloadAfter: false))))
        await probe.started.wait()
        // A cancelled request must stay tracked until its asynchronous unwind ends.
        if cancelFirst { #expect(loop.submit(.init(id: id, request: .cancel))) }
        if explicitRequest { #expect(loop.submit(.init(id: UUID(), request: .forceUnload))) }
        let stopping = loop.stop()
        await probe.cancellation.wait()
        #expect(!loop.submit(.init(id: UUID(), request: .prepareModels)))
        await probe.release.signal()
        await stopping.value
        await loop.stop().value
        #expect(await probe.events == ["started", "cancelled and drained", "unloaded"])
    }
}

extension ModelLifetimeTests {
    @Test func rejectedShutdownRequestReceivesTerminalError() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let loop = RequestLoop(backend: MockBackend(), writer: StdoutWriter(pipe.fileHandleForWriting))
        await loop.stop().value
        let id = UUID()
        #expect(!loop.submit(.init(id: id, request: .prepareModels)))
        let data = await Task.detached { pipe.fileHandleForReading.availableData }.value
        var reader = FrameReader()
        reader.append(data)
        let payload = try #require(reader.drainFrames().first)
        let reply = try JSONDecoder().decode(EventEnvelope.self, from: payload)
        #expect(reply.id == id)
        guard case .error = reply.event else {
            Issue.record("Rejected request needs an error to resume its waiting caller"); return
        }
    }
}
