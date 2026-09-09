import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Capture live ownership") @MainActor
struct CaptureLiveOwnershipTests {
    @MainActor private final class Harness {
        var calls: [String] = []
        var events: [String] = []
        var sinks: [CaptureCoordinator.HardwareSink] = []
        var liveSinks: [@Sendable (CaptureLivePreview.Event) -> Void] = []
        var inputs: [CaptureLivePreview.Inputs] = []
        var hold: String?
        var waiter: CheckedContinuation<Void, Never>?
        var clocks: [CheckedContinuation<Void, Never>] = []
        var trace = false
        var context: PrivacyTrace.Context?
        var receivedContext: PrivacyTrace.Context?
        var mic = true, system = false
        func step(_ name: String) async {
            calls.append(name)
            if hold == name { await withCheckedContinuation { waiter = $0 } }
        }
        func release() { hold = nil; waiter?.resume(); waiter = nil }
        func prepare() async -> PrivacyTrace.Context? { await step("prepare"); return context }
        func clock() async { await withCheckedContinuation { clocks.append($0) } }
        func makeSession() -> CaptureLivePreview.Session {
            return .init(start: { input, sink in
                await self.receive(input, sink: sink)
                await self.step("live-start")
                if await self.trace {
                    try? await PrivacyTrace.perform(.init(stage: .liveTranscription, data: [.recordingAudio],
                                                        destination: .local(provider: .appleSpeech))) {}
                    await self.step("traced")
                }
            }, stop: {
                await self.step("live-stop")
            })
        }
        func receive(_ input: CaptureLivePreview.Inputs, sink: @escaping @Sendable (CaptureLivePreview.Event) -> Void) {
            inputs.append(input); liveSinks.append(sink); receivedContext = PrivacyTrace.context
        }
        func coordinator(previewOverride: CaptureLivePreview? = nil) -> CaptureCoordinator {
            CaptureCoordinator(hardware: .init(start: { _, _ in
                .init(mic: AsyncStream { _ in }, system: AsyncStream { _ in })
            }, stop: { await self.step("hardware-stop") }, snapshot: {
                .init(duration: 4, microphoneEnabled: self.mic, systemAudioEnabled: self.system)
            }, pause: {}, resume: {}, switchInputDevice: { _ in }, bindEvents: { sink in
                if let sink { self.sinks.append(sink) }
            }), persistence: .init(create: { id, date in
                let root = URL(fileURLWithPath: "/tmp/live-owner/\(id)")
                return .init(id: id, startedAt: date, files: .init(directoryURL: root,
                    manifestURL: root.appendingPathComponent("session.json"), captureBaseURL: root.appendingPathComponent("capture")))
            }, began: { _, _ in }, failedStart: { _, _, _ in }, stopped: { session, state, _ in
                await self.step("checkpoint")
                return .init(session: session, state: state, fileSize: 1, duration: 4)
            }, termination: { _ in }, pauseResume: { _, _, _ in }),
            preview: previewOverride ?? .init(prepare: { _ in await self.prepare() }, make: { self.makeSession() }),
            sleep: { _ in await self.clock() }, onEvent: { event in
                switch event {
                case .liveBegan: self.events.append("live-began")
                case .liveEnded: self.events.append("live-ended")
                case .live(_, let event):
                    switch event {
                    case .finalized: self.events.append("finalized")
                    case .volatile: self.events.append("volatile")
                    case .status: self.events.append("live-status")
                    }
                case .meter: self.events.append("meter")
                case .status(_, let text): self.events.append(text ?? "cleared")
                case .stopped: self.events.append("stopped")
                default: break
                }
            })
        }
    }
    private func request(live: Bool = true) -> CaptureCoordinator.Request {
        .init(id: UUID(), startedAt: Date(), liveTranscription: live, language: "nl")
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test func stopDuringReceiptPreparationClosesHardwareAndLiveBeforeJoiningPreparation() async throws {
        let h = Harness(), owner = h.coordinator(); h.hold = "prepare"
        try await owner.start(request())
        try await wait { h.waiter != nil }
        let stop = Task { await owner.stop() }
        try await wait { h.calls.contains("hardware-stop") && h.calls.contains("live-stop") }
        #expect(owner.isBusy && !h.calls.contains("live-start"))
        #expect(h.events.contains("live-ended") && !h.events.contains("stopped"))
        stop.cancel()
        h.release(); await stop.value
        #expect(!owner.isBusy && !h.calls.contains("live-start"))
    }

    @Test func stopJoinsCancellationIgnoringLiveStartBeforeReleasingAdmission() async throws {
        let h = Harness(), owner = h.coordinator(); h.hold = "live-start"
        try await owner.start(request())
        try await wait { h.waiter != nil }
        let stop = Task { await owner.stop() }
        try await wait { h.calls.contains("live-stop") && h.calls.contains("hardware-stop") }
        #expect(owner.isBusy && !h.events.contains("stopped"))
        h.liveSinks[0](.status("late start"))
        await Task.yield()
        #expect(!h.events.contains("live-status"))
        h.release(); await stop.value
        #expect(!owner.isBusy && h.events.last == "stopped")
    }

    @Test func liveAdapterReceiptPreparationUsesOriginalScopeThroughFinalAudioBinding() async throws {
        let h = Harness(); h.trace = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-live-receipt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PrivacyReceiptStore(gapDirectoryURL: root.appendingPathComponent("gaps"))
        var input = request()
        let scope = RecordingPrivacyScope(recordingID: input.id, store: store, pendingRootURL: root.appendingPathComponent("pending"))
        input.privacyScope = scope
        let owner = h.coordinator(previewOverride: .init(prepare: CaptureLivePreview.live().prepare, make: { h.makeSession() }))
        try await owner.start(input)
        try await wait { h.calls.contains("traced") }
        await owner.stop()
        let audio = root.appendingPathComponent("finished.wav")
        await scope.bind(to: audio)
        let receipt = try #require(try await store.load(from: PrivacyReceiptStore.sidecarURL(for: audio)))
        #expect(receipt.attempts.count == 1)
        #expect(receipt.attempts[0].operation.stage == .liveTranscription)
        #expect(receipt.attempts[0].outcome == .succeeded)
        #expect(h.receivedContext?.recordingID == input.id)
    }

    @Test(arguments: [false, true])
    func stopJoinsLiveCleanupAndRejectsLateEventsAfterReplacement(terminating: Bool) async throws {
        let h = Harness(), owner = h.coordinator()
        try await owner.start(request())
        try await wait { !h.liveSinks.isEmpty }
        let oldLive = h.liveSinks[0], oldHardware = h.sinks[0]
        h.hold = "live-stop"
        let stop = Task { await owner.stop(terminating: terminating) }
        try await wait { h.waiter != nil && h.calls.contains("hardware-stop") }
        let count = h.events.count
        oldHardware(.meter(8, 1)); oldHardware(.status("retired"))
        oldLive(.status("retired")); oldLive(.volatile("You", "retired")); oldLive(.finalized([]))
        await Task.yield()
        #expect(h.events.count == count && owner.isBusy)
        h.release(); await stop.value
        if !terminating {
            try await owner.start(request())
            try await wait { h.liveSinks.count == 2 }
            let before = h.events.count
            oldHardware(.meter(9, 1)); oldHardware(.status("retired")); oldLive(.finalized([]))
            h.liveSinks[1](.status("current"))
            try await wait { h.events.count > before }
            #expect(Array(h.events.dropFirst(before)) == ["live-status"])
            await owner.stop()
        }
    }

    @Test(arguments: [(true, false), (false, true), (true, true)])
    func previewFreezesChannelsLanguageAndReceiptAndKeepsPausedResults(channels: (Bool, Bool)) async throws {
        let h = Harness(); h.mic = channels.0; h.system = channels.1
        let id = UUID(), root = FileManager.default.temporaryDirectory.appendingPathComponent("live-context-\(UUID())")
        let store = PrivacyReceiptStore()
        h.context = .init(receiptURL: root.appendingPathComponent("receipt.json"), store: store, runID: UUID(), recordingID: id)
        let owner = h.coordinator()
        h.hold = "prepare"
        try await owner.start(request())
        try await wait { h.waiter != nil }
        h.mic = !channels.0; h.system = !channels.1
        h.release()
        try await wait { !h.inputs.isEmpty }
        #expect((h.inputs[0].mic != nil) == channels.0 && (h.inputs[0].system != nil) == channels.1)
        #expect(h.inputs[0].language == "nl" && h.receivedContext?.recordingID == id)
        #expect(h.receivedContext?.runID == h.context?.runID)
        owner.pause()
        let before = h.events.count
        h.sinks[0](.meter(10, 1))
        h.liveSinks[0](.finalized([]))
        try await wait { h.events.count > before }
        #expect(Array(h.events.dropFirst(before)) == ["finalized"])
        try owner.resume()
        h.sinks[0](.meter(11, 1))
        #expect(h.events.last == "meter" && h.inputs.count == 1)
        await owner.stop()
    }

    @Test func supersededStatusExpiryCannotClearNewNoteOrReplacement() async throws {
        let h = Harness(), owner = h.coordinator()
        try await owner.start(request(live: false))
        h.sinks[0](.status("first"))
        try await wait { h.clocks.count == 1 }
        h.sinks[0](.status("second"))
        try await wait { h.clocks.count == 2 }
        h.clocks[0].resume()
        await Task.yield()
        #expect(h.events.last == "second")
        await owner.stop()
        try await owner.start(request(live: false))
        h.sinks[1](.status("replacement"))
        try await wait { h.clocks.count == 3 }
        h.clocks[1].resume()
        await Task.yield()
        #expect(h.events.last == "replacement")
        h.clocks[2].resume()
        try await wait { h.events.last == "cleared" }
        #expect(!h.calls.contains("prepare") && !h.events.contains("live-began"))
        await owner.stop()
    }
}
