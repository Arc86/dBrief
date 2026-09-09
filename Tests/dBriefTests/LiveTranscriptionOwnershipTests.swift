import Foundation
import Testing
@testable import dBrief

@Suite("Live transcription task ownership") @MainActor
struct LiveTranscriptionOwnershipTests {
    @MainActor private final class Runner {
        var pending: [LiveTranscriptionService.Channel: CheckedContinuation<Void, Never>] = [:]
        var started: [LiveTranscriptionService.Channel] = []
        var cancelled: Set<LiveTranscriptionService.Channel> = []
        var ended: [LiveTranscriptionService.Channel] = []
        var contexts: [UUID?] = []
        func run(_ request: LiveTranscriptionService.ChannelRequest) async {
            started.append(request.channel)
            contexts.append(PrivacyTrace.context?.recordingID)
            await withTaskCancellationHandler {
                await withCheckedContinuation { pending[request.channel] = $0 }
            } onCancel: {
                Task { @MainActor in self.cancelled.insert(request.channel) }
            }
            #expect(Task.isCancelled)
            request.onStatus("late cleanup result")
            ended.append(request.channel)
        }
        func release(_ channel: LiveTranscriptionService.Channel) { pending.removeValue(forKey: channel)?.resume() }
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }
    private func start(_ service: LiveTranscriptionService) async {
        await service.start(mic: AsyncStream { _ in }, system: AsyncStream { _ in }, language: "nl",
                            onFinalized: { _ in }, onVolatile: { _, _ in }, onStatus: { _ in })
    }

    @Test func concurrentStopsJoinBothChannelsAndPreserveOriginalReceiptContext() async throws {
        let runner = Runner(), service = LiveTranscriptionService(runChannel: { await runner.run($0) })
        let id = UUID()
        let context = PrivacyTrace.Context(receiptURL: URL(fileURLWithPath: "/tmp/synthetic-live.json"),
                                           store: PrivacyReceiptStore(), runID: UUID(), recordingID: id)
        await PrivacyTrace.$context.withValue(context) { await start(service) }
        try await wait { runner.pending.count == 2 }
        await start(service) // Duplicate Start cannot add another pair of channels.
        var stopped = 0
        let one = Task { await service.stop(); stopped += 1 }
        try await wait { runner.cancelled.count == 2 }
        let two = Task { await service.stop(); stopped += 1 }
        await Task.yield()
        #expect(stopped == 0)
        runner.release(.mic)
        try await wait { runner.ended.count == 1 }
        #expect(stopped == 0)
        runner.release(.system)
        await one.value; await two.value
        #expect(stopped == 2 && runner.started.count == 2 && runner.ended.count == 2)
        #expect(runner.contexts.allSatisfy { $0 == id })
        await start(service)
        #expect(runner.started.count == 2)
    }

    @Test func stoppingBeforeStartPreventsChannelDispatch() async {
        let service = LiveTranscriptionService(runChannel: { _ in Issue.record("Retired service dispatched a channel") })
        await service.stop()
        await start(service)
        await service.stop()
    }
}
