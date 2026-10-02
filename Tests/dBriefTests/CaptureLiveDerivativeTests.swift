import AVFoundation
import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite struct CaptureLiveDerivativeTests {
    @MainActor private final class Harness {
        @MainActor private final class Channel { var consumer: Task<Void, Never>? }
        var calls: [String] = []
        var scopes: [LiveSessionIdentity] = []
        var wrongOwner = false
        var holdPreparation = false
        var holdDrain = false
        var preparationWaiter: CheckedContinuation<Void, Never>?
        var drainWaiter: CheckedContinuation<Void, Never>?
        var preparation: Task<Void, Never>?
        var consumer: Task<Void, Never>?
        var micOutput: AsyncStream<LiveAudioBuffer>.Continuation?
        var systemOutput: AsyncStream<LiveAudioBuffer>.Continuation?
        var received: [Float] = []
        var expired: Set<UUID> = []

        func makeBuffer(_ samples: [Float]) -> LiveAudioBuffer {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000,channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format,frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for (index,sample) in samples.enumerated() { buffer.floatChannelData![0][index] = sample }
            return LiveAudioBuffer(buffer)
        }
        func makeSession(_ request: CaptureCoordinator.Request) -> CaptureLiveDerivative.Session {
            let identity = LiveSessionIdentity(recordingID: request.id,captureSessionID: wrongOwner ? UUID() : request.captureSessionID)
            let channel = Channel()
            scopes.append(identity)
            return .init(identity: identity,register: { input in
                self.calls.append("register")
                #expect(input.language == request.language)
                #expect(input.mic != nil && input.system == nil)
                self.preparation = Task {
                    if self.holdPreparation { await withCheckedContinuation { self.preparationWaiter = $0 } }
                    if !self.expired.contains(identity.captureSessionID) { self.calls.append("prepared-native") }
                }
                self.consumer = Task {
                    if let mic = input.mic {
                        for await item in mic {
                            self.received.append(contentsOf: UnsafeBufferPointer(start: item.buffer.floatChannelData![0],count: Int(item.buffer.frameLength)))
                        }
                    }
                    self.calls.append("converter-tail")
                }
                channel.consumer = self.consumer
            },beginClosing: { self.calls.append("retire-input") },hardwareDidClose: {
                await self.drain(channel)
            },expire: { self.expired.insert(identity.captureSessionID); self.calls.append("expire") },
            pause: { self.calls.append("derivative-pause") },resume: { self.calls.append("derivative-resume") },
            inputDeviceChanged: { self.calls.append("derivative-device") })
        }
        private func drain(_ channel: Channel) async {
            calls.append("drain")
            if holdDrain { await withCheckedContinuation { drainWaiter = $0 } }
            await channel.consumer?.value
            calls.append("finish-barrier")
        }
        func release() {
            holdPreparation = false; holdDrain = false
            preparationWaiter?.resume(); preparationWaiter = nil
            drainWaiter?.resume(); drainWaiter = nil
        }
        func coordinator() -> CaptureCoordinator {
            .init(hardware: .init(start: { _, _ in
                let (mic,micOutput) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(4))
                let (system,systemOutput) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(4))
                self.micOutput = micOutput; self.systemOutput = systemOutput
                self.calls.append("hardware-start")
                return .init(mic: mic,system: system)
            },stop: {
                self.calls.append("hardware-stop")
                self.micOutput?.yield(self.makeBuffer([0.25,0.5]))
                self.micOutput?.finish(); self.systemOutput?.finish()
            },snapshot: { .init(duration: 4,microphoneEnabled: true) },
            pause: { self.calls.append("hardware-pause") },resume: { self.calls.append("hardware-resume") },
            switchInputDevice: { _ in self.calls.append("hardware-device") }),
            persistence: .init(create: { id,date in
                let root = URL(fileURLWithPath: "/tmp/capture-derivative/\(id)")
                return .init(id: id,startedAt: date,files: .init(directoryURL: root,manifestURL: root.appendingPathComponent("session.json"),captureBaseURL: root.appendingPathComponent("capture")))
            },began: { _, _ in },failedStart: { _, _, _ in },stopped: { session,state,_ in
                await self.checkpoint(); return .init(session: session,state: state,fileSize: 1,duration: 4)
            },termination: { _ in },pauseResume: { _, _, _ in }),
            preview: .init(prepare: { _ in nil },make: { .init(start: { _, _ in await self.appleStarted() },stop: {}) }),
            derivative: .init(make: { request,_ in self.makeSession(request) }),derivativeDrainDeadline: .milliseconds(60),
            onEvent: { event in if case .stopped = event { self.calls.append("stopped") } })
        }
        func checkpoint() { calls.append("checkpoint") }
        func appleStarted() { calls.append("apple-start") }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: TestTiming.asyncDeadline)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(condition())
    }
    private func request() -> CaptureCoordinator.Request { .init(id: UUID(),startedAt: Date(),liveTranscription: true,language: "nl") }

    @Test func hardwareClosesBeforeRegisteredTailAndBarrierWithoutJoiningPreparation() async throws {
        let h = Harness(), c = h.coordinator(); h.holdPreparation = true
        try await c.start(request())
        // Do not let a missing implementation hang the RED run.
        for _ in 0..<50 { if h.preparationWaiter != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(h.preparationWaiter != nil)
        await c.stop()
        #expect(h.received == [0.25,0.5])
        #expect(h.calls.contains("register") && !h.calls.contains("apple-start"))
        if let retire = h.calls.firstIndex(of: "retire-input"), let hardware = h.calls.firstIndex(of: "hardware-stop"),
           let finish = h.calls.firstIndex(of: "finish-barrier"), let saved = h.calls.firstIndex(of: "checkpoint") {
            #expect(retire < hardware && hardware < finish && finish < saved)
        } else { Issue.record("Missing capture-owned drain steps") }
        #expect(!c.isBusy && h.preparationWaiter != nil)
        h.release(); await h.preparation?.value
    }

    @Test func independentDeadlineReleasesAudioAdmissionAndExpiresOnlyTheOldDerivative() async throws {
        let h = Harness(), c = h.coordinator(), old = request(); h.holdDrain = true
        try await c.start(old)
        let clock = ContinuousClock(), start = clock.now
        await c.stop()
        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(!c.isBusy && h.calls.contains("checkpoint"))
        #expect(h.expired == [old.captureSessionID])
        h.release()
        let next = request(); try await c.start(next)
        #expect(h.scopes.last?.captureSessionID == next.captureSessionID)
        #expect(!h.expired.contains(next.captureSessionID))
        await c.stop()
    }

    @Test func controlsFollowTheOwnedDerivativeAndTerminalLatchRejectsFurtherControls() async throws {
        let h = Harness(), c = h.coordinator()
        try await c.start(request())
        c.pause(); try c.resume(); try c.switchInputDevice(to: "selected")
        #expect(h.calls.contains("derivative-pause") && h.calls.contains("derivative-resume") && h.calls.contains("derivative-device"))
        await c.stop()
        let before = h.calls
        c.pause(); try c.resume(); try c.switchInputDevice(to: "late")
        #expect(h.calls == before)
    }

    @Test func mismatchedDerivativeIdentityNeverRegistersCaptureAudio() async throws {
        let h = Harness(), c = h.coordinator(); h.wrongOwner = true
        try await c.start(request())
        await c.stop()
        #expect(!h.calls.contains("register") && h.calls.contains("expire"))
    }
}
