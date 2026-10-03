import Foundation
import Testing
import MLXLMCommon
import dBriefWire
@testable import dBriefMLHost

@Suite("Native chat actual producer lifetime")
struct NativeChatGenerationLifetimeTests {
    @Test func consumerCancellationCannotReleaseAHeldOrNotYetStartedProducer() async throws {
        let gate = NativeChatReturnGate(), probe = NativeChatReturnProbe()
        let (stream, continuation) = AsyncStream<Generation>.makeStream()
        let producer = Task { await gate.hold(); continuation.finish() }
        let consume = Task {
            do { try await MLXInsightsService.consumeChatGeneration(stream: stream, producer: producer, emit: { _ in }) }
            catch { await probe.failure(error is CancellationError) }
            await probe.finish()
        }
        consume.cancel()
        await gate.waitForArrival()
        for _ in 0..<20 { await Task.yield() }
        #expect(await probe.finished == false)
        await gate.release()
        await consume.value
        let finished = await probe.finished, cancelled = await probe.wasCancelled
        #expect(finished && cancelled)
    }

    @Test func EOFWithoutCompletionRemainsUnconfirmedEvenAfterNativeReturn() async throws {
        let (stream, continuation) = AsyncStream<Generation>.makeStream()
        let producer = Task { continuation.yield(.chunk("Partial")); continuation.finish() }
        do {
            try await MLXInsightsService.consumeChatGeneration(stream: stream, producer: producer, emit: { _ in })
            Issue.record("Missing native terminal was accepted")
        } catch let error as WireError { #expect(error.kind == .chatUnconfirmed) }
    }
}

private actor NativeChatReturnProbe {
    private(set) var finished = false, wasCancelled = false
    func failure(_ cancelled: Bool) { wasCancelled = cancelled }
    func finish() { finished = true }
}
private actor NativeChatReturnGate {
    private var arrived = false, released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { arrived = true; if !released { await withCheckedContinuation { continuation = $0 } } }
    func waitForArrival() async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !arrived, ContinuousClock.now < deadline { await Task.yield() }
        #expect(arrived)
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
