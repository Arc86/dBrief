import Foundation
import Testing
@testable import dBrief

@Suite("Capture lifecycle ownership") @MainActor
struct CaptureCoordinatorTests {
    @MainActor private final class Harness {
        var calls: [String] = []
        var events: [String] = []
        var requests: [CaptureCoordinator.Request] = []
        var hardwareDuration: Double = 7
        var stopSnapshotTaken = false
        var checkpointDurations: [Double] = []
        var receivedState: CaptureSessionStore.CaptureState?
        var hold: String?
        var fail: String?
        var waiter: CheckedContinuation<Void, Never>?
        weak var owner: CaptureCoordinator?
        func step(_ name: String) async throws {
            calls.append(name)
            if hold == name { await withCheckedContinuation { waiter = $0 } }
            if fail == name { throw CocoaError(.fileWriteUnknown) }
        }
        func release() { hold = nil; waiter?.resume(); waiter = nil }
        func receiveCheckpoint(_ state: CaptureSessionStore.CaptureState) { checkpointDurations.append(state.duration) }
        func receive(_ state: CaptureSessionStore.CaptureState) { receivedState = state }
        func session(id: UUID, date: Date) -> CaptureSessionStore.Session {
            let root = URL(fileURLWithPath: "/tmp/synthetic-capture/\(id)")
            return .init(id: id, startedAt: date, files: .init(directoryURL: root,
                manifestURL: root.appendingPathComponent("session.json"), captureBaseURL: root.appendingPathComponent("capture")))
        }
        var state: CaptureSessionStore.CaptureState {
            .init(tracks: .init(systemURL: nil, micURL: URL(fileURLWithPath: "/tmp/synthetic-capture/mic.caf")),
                  duration: hardwareDuration, microphoneEnabled: true)
        }
        func coordinator() -> CaptureCoordinator {
            let value = CaptureCoordinator(hardware: .init(start: { request, _ in
                self.requests.append(request)
                try await self.step("hardware-start")
                return nil
            }, stop: { try? await self.step("hardware-stop") }, snapshot: {
                if self.calls.contains("hardware-stop") { self.stopSnapshotTaken = true }
                return self.state
            },
            pause: { self.calls.append("hardware-pause") }, resume: {
                self.calls.append("hardware-resume")
                if self.fail == "resume" { throw CocoaError(.fileReadUnknown) }
            }, switchInputDevice: { uid in self.calls.append("device-" + (uid ?? "default")) }),
            persistence: .init(create: { id, date in
                try await self.step("create")
                return await self.session(id: id, date: date)
            }, began: { _, _ in try await self.step("capturing") }, failedStart: { _, _, _ in
                try? await self.step("failed-start")
            }, stopped: { session, state, terminating in
                await self.receive(state)
                try? await self.step(terminating ? "termination" : "stopped")
                return .init(session: session, state: state, fileSize: 100, duration: 7)
            }, termination: { _ in try? await self.step("upgrade-termination") },
            pauseResume: { _, state, paused in
                await self.receiveCheckpoint(state)
                try? await self.step(paused ? "paused" : "resumed")
            }),
            onEvent: { event in
                #expect(self.owner?.isBusy == true)
                switch event {
                case .prepared: self.events.append("prepared")
                case .started: self.events.append("started")
                case .stopped(_, let terminating): self.events.append(terminating ? "terminated" : "stopped")
                case .failed: self.events.append("failed")
                case .paused: self.events.append("paused")
                case .resumed: self.events.append("resumed")
                case .liveBegan, .liveEnded, .live, .meter, .status: break
                }
            })
            owner = value
            return value
        }
    }
    private func request() -> CaptureCoordinator.Request {
        .init(id: UUID(), startedAt: Date(timeIntervalSince1970: 50), inputDeviceUID: "selected-input",
              acousticEchoCancellation: true, echoSuppression: true, liveTranscription: true, language: "nl")
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test(arguments: [false, true])
    func rapidControlsKeepCheckpointOrderAndStopClosesHardwareBeforeWaiting(terminating: Bool) async throws {
        let h = Harness(), owner = h.coordinator()
        try await owner.start(request())
        h.hold = "paused"
        owner.pause()
        owner.pause() // Duplicate intent must not add hardware or persistence work.
        try await wait { h.waiter != nil }
        h.hardwareDuration = 8
        try owner.resume()
        try owner.resume()
        h.hardwareDuration = 9
        owner.pause()
        #expect(h.events.suffix(3) == ["paused", "resumed", "paused"])
        let stop = Task { await owner.stop(terminating: terminating) }
        try await wait { h.stopSnapshotTaken }
        stop.cancel()
        #expect(owner.isBusy)
        #expect(!h.calls.contains("stopped") && !h.calls.contains("termination"))
        owner.pause(); try owner.resume(); try owner.switchInputDevice(to: "retired")
        #expect(!h.calls.contains("device-retired"))
        h.hardwareDuration = 99
        h.release()
        await stop.value
        #expect(h.checkpointDurations == [7, 8, 9])
        #expect(h.receivedState?.duration == 9)
        #expect(h.calls.filter { ["paused", "resumed", "stopped", "termination"].contains($0) }
                == ["paused", "resumed", "paused", terminating ? "termination" : "stopped"])
        #expect(h.calls.filter { $0 == "hardware-pause" }.count == 2)
        #expect(h.calls.filter { $0 == "hardware-resume" }.count == 1)
    }

    @Test func failedResumeKeepsPausedStateAndDoesNotWriteResumedCheckpoint() async throws {
        let h = Harness(), owner = h.coordinator()
        try await owner.start(request())
        owner.pause()
        h.fail = "resume"
        #expect(throws: CocoaError.self) { try owner.resume() }
        owner.pause()
        try owner.switchInputDevice(to: "paused-device")
        #expect(h.events == ["prepared", "started", "paused"])
        h.fail = nil
        try owner.resume()
        await owner.stop()
        #expect(h.calls.filter { $0 == "hardware-pause" }.count == 1)
        #expect(h.calls.filter { $0 == "resumed" }.count == 1)
        #expect(h.calls.contains("device-paused-device"))
    }

    @Test(arguments: ["create", "hardware-start", "capturing"])
    func controlsAreIgnoredUntilStartedAndAfterStopped(stage: String) async throws {
        let h = Harness(), owner = h.coordinator()
        h.hold = stage
        let start = Task { try await owner.start(request()) }
        try await wait { h.waiter != nil }
        owner.pause(); try owner.resume(); try owner.switchInputDevice(to: "starting")
        h.release(); try await start.value
        try owner.switchInputDevice(to: "active")
        await owner.stop()
        owner.pause(); try owner.resume(); try owner.switchInputDevice(to: "stopped")
        #expect(!h.calls.contains("hardware-pause") && !h.calls.contains("hardware-resume"))
        #expect(h.calls.filter { $0.hasPrefix("device-") } == ["device-active"])
    }

    @Test func startFreezesRequestAndStopPublishesBeforeReleasingOwnership() async throws {
        let h = Harness(), input = request()
        let owner = h.coordinator()
        try await owner.start(input)
        #expect(owner.recordingID == input.id && owner.isBusy)
        #expect(h.requests.first?.inputDeviceUID == "selected-input")
        #expect(h.requests.first?.language == "nl")
        #expect(h.calls == ["create", "hardware-start", "capturing"])
        await owner.stop()
        #expect(h.calls == ["create", "hardware-start", "capturing", "hardware-stop", "stopped"])
        #expect(h.events == ["prepared", "started", "stopped"])
        #expect(!owner.isBusy && owner.recordingID == nil)
        await owner.stop()
        #expect(h.events.count == 3)
    }

    @Test(arguments: ["create", "hardware-start", "capturing"], [false, true])
    func stopDuringStartupWaitsForOwnedWorkAndNeverPublishesActive(stage: String, terminating: Bool) async throws {
        let h = Harness(); h.hold = stage
        let owner = h.coordinator()
        let start = Task { try await owner.start(request()) }
        try await wait { h.waiter != nil }
        await #expect(throws: CaptureCoordinator.Failure.self) { try await owner.start(request()) }
        let stop = Task { await owner.stop(terminating: terminating) }
        try await wait { owner.isStopping }
        #expect(owner.isBusy)
        #expect(!h.events.contains("stopped"))
        h.release()
        try await start.value
        await stop.value
        #expect(!h.events.contains("started"))
        #expect(h.events == ["prepared", terminating ? "terminated" : "stopped"])
        #expect(h.calls.filter { $0 == "hardware-stop" }.count == (stage == "create" ? 0 : 1))
        #expect(owner.isBusy == terminating)
    }

    @Test func doubleStopSharesOneHardwareCloseAndOneTerminalPublication() async throws {
        let h = Harness(), owner = h.coordinator()
        try await owner.start(request())
        h.hold = "hardware-stop"
        let first = Task { await owner.stop() }
        try await wait { h.waiter != nil }
        let second = Task { await owner.stop() }
        await Task.yield()
        #expect(h.calls.filter { $0 == "hardware-stop" }.count == 1)
        h.release()
        await first.value; await second.value
        #expect(h.events.filter { $0 == "stopped" }.count == 1)
    }

    @Test func terminationUpgradesAnAlreadyCheckpointingStopWithoutArmingPostRecording() async throws {
        let h = Harness(), owner = h.coordinator()
        try await owner.start(request())
        h.hold = "stopped"
        let stop = Task { await owner.stop() }
        try await wait { h.waiter != nil }
        let quit = Task { await owner.stop(terminating: true) }
        try await wait { owner.isTerminating }
        h.release()
        await stop.value; await quit.value
        #expect(h.calls.filter { $0 == "hardware-stop" }.count == 1)
        #expect(h.calls.contains("upgrade-termination"))
        #expect(h.events.last == "terminated")
        #expect(!h.events.contains("stopped"))
    }

    @Test(arguments: ["create", "hardware-start", "capturing"])
    func startupFailureClosesOwnedHardwareBeforeFailureCleanupAndPublication(stage: String) async throws {
        let h = Harness(); h.fail = stage
        let owner = h.coordinator()
        await #expect(throws: CocoaError.self) { try await owner.start(request()) }
        #expect(h.calls.filter { $0 == "hardware-stop" }.count == (stage == "create" ? 0 : 1))
        if stage != "create" {
            #expect(h.calls.suffix(2) == ["hardware-stop", "failed-start"])
        }
        #expect(h.events.last == "failed")
        #expect(!h.events.contains("started") && !owner.isBusy)
    }

    @Test func cancelledStartupWaitsForIgnoringHardwareBeforeReplacementCanStart() async throws {
        let h = Harness(); h.hold = "hardware-start"
        let owner = h.coordinator()
        let original = Task { try await owner.start(request()) }
        try await wait { h.waiter != nil }
        original.cancel()
        try await wait { owner.isStopping }
        await #expect(throws: CaptureCoordinator.Failure.self) { try await owner.start(request()) }
        #expect(!h.calls.contains("hardware-stop"))
        h.release()
        await #expect(throws: CancellationError.self) { try await original.value }
        #expect(!owner.isBusy && !h.events.contains("started"))
        let replacement = request()
        try await owner.start(replacement)
        original.cancel()
        await Task.yield()
        #expect(owner.recordingID == replacement.id)
        #expect(h.calls.filter { $0 == "hardware-stop" }.count == 1)
        await owner.stop()
    }

    @Test func cancellingStopCallerDoesNotReleasePendingCheckpoint() async throws {
        let h = Harness(), owner = h.coordinator()
        try await owner.start(request())
        h.hold = "stopped"
        let stop = Task { await owner.stop() }
        try await wait { h.waiter != nil }
        stop.cancel()
        #expect(owner.isBusy && !h.events.contains("stopped"))
        h.release()
        await stop.value
        #expect(!owner.isBusy && h.events.last == "stopped")
    }

    @Test func cancelledEntryDoesNotReserveCreateOrDispatchHardware() async throws {
        let h = Harness(), owner = h.coordinator()
        let start = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await owner.start(request())
        }
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(h.calls.isEmpty && h.events.isEmpty && !owner.isBusy)
    }

    @Test func terminationWithoutCaptureStillPreventsLaterStart() async throws {
        let h = Harness(), owner = h.coordinator()
        await owner.stop(terminating: true)
        await #expect(throws: CaptureCoordinator.Failure.self) { try await owner.start(request()) }
        #expect(h.calls.isEmpty && h.events.isEmpty)
    }

    @Test func stoppedFactsCannotChangeWhilePersistenceIsSuspended() async throws {
        let h = Harness(), owner = h.coordinator()
        try await owner.start(request())
        h.hold = "stopped"
        let stop = Task { await owner.stop() }
        try await wait { h.waiter != nil }
        h.hardwareDuration = 99
        #expect(h.receivedState?.duration == 7)
        h.release()
        await stop.value
        #expect(h.receivedState?.duration == 7)
    }
}
