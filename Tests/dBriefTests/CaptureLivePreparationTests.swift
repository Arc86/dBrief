import AVFoundation
import Foundation
import Testing
import dBriefWire
@testable import dBrief

private actor PreparationNativeFixture {
    private let events: AsyncThrowingStream<LiveSessionEvent, Error>
    private let output: AsyncThrowingStream<LiveSessionEvent, Error>.Continuation
    private(set) var begins = 0
    private(set) var beginInputs: [LiveSessionBegin] = []
    private(set) var beginWaiter: CheckedContinuation<Void, Never>?
    private(set) var beginReturned = false
    private(set) var shutdowns = 0
    private(set) var shutdownReturned = false
    private(set) var shutdownWaiter: CheckedContinuation<Void, Never>?
    var holdShutdown = false
    var holdBegin = false
    init() {
        (events,output) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(32))
    }
    nonisolated var transport: LiveASRTransport {
        .init(begin: { await self.begin($0) },command: { _ in .accepted },deadline: { _ in },shutdown: { await self.shutdown() })
    }
    private func begin(_ input: LiveSessionBegin) async -> AsyncThrowingStream<LiveSessionEvent, Error> {
        begins += 1
        beginInputs.append(input)
        if holdBegin { await withCheckedContinuation { beginWaiter = $0 } }
        for epoch in input.epochs {
            output.yield(.lane(.init(scope: .init(identity: input.identity,source: epoch.source,epochID: epoch.id),
                sequence: 0,payload: .ready(generation: UUID(),originSample: 0))))
        }
        beginReturned = true
        return events
    }
    func setHoldBegin() { holdBegin = true }
    func setHoldShutdown() { holdShutdown = true }
    private func shutdown() async {
        shutdowns += 1
        if holdShutdown { await withCheckedContinuation { shutdownWaiter = $0 } }
        shutdownReturned = true; output.finish()
    }
    func release() {
        holdBegin = false; beginWaiter?.resume(); beginWaiter = nil
        holdShutdown = false; shutdownWaiter?.resume(); shutdownWaiter = nil
    }
}

@Suite("Prepared capture derivative ownership") @MainActor
struct CaptureLivePreparationTests {
    @MainActor private final class Harness {
        var calls: [String] = []
        var events: [String] = []
        var hardwareRequests: [CaptureCoordinator.Request] = []
        var preparedRequests: [CaptureCoordinator.Request] = []
        var preparations: [CaptureLiveDerivative.Prepared] = []
        var registered: [CaptureLivePreview.Inputs] = []
        var closing: [UUID] = []
        var expired: [UUID] = []
        var stopPoint: String?
        var reentryPoint: String?
        var reentries = 0
        var observedSynchronousStop = false
        var invalid: String?
        var nilPreparation = false
        var legacySession = false
        var registrationAccepted = true
        var bothSources = false
        var microphoneEnabled = true
        var systemEnabled = false
        var returnsStreams = true
        var hold: String?
        var failure: String?
        var waiter: CheckedContinuation<Void, Never>?
        var holdDrain = false
        var drainWaiter: CheckedContinuation<Void, Never>?
        var drainsReturned: [UUID] = []
        var holdDeadline = false
        var deadlineWaiter: CheckedContinuation<Void, Never>?
        var override: CaptureLiveDerivative.Prepared?
        weak var owner: CaptureCoordinator?
        private var outputs: [AsyncStream<LiveAudioBuffer>.Continuation] = []

        func stopAt(_ point: String) {
            if stopPoint == point {
                owner?.requestStop()
                observedSynchronousStop = owner?.isStopping == true
            }
        }
        func reenter(_ point: String) {
            guard reentryPoint == point else { return }
            reentries += 1
            // Bound a broken implementation so RED cannot recurse indefinitely.
            if reentries <= 3 { owner?.requestStop(terminating: true) }
        }
        func step(_ name: String) async throws {
            calls.append(name)
            if hold == name { await withCheckedContinuation { waiter = $0 } }
            if failure == name { throw CocoaError(.fileWriteUnknown) }
        }
        func release() {
            hold = nil; waiter?.resume(); waiter = nil
            holdDrain = false; drainWaiter?.resume(); drainWaiter = nil
            releaseDeadline()
        }
        func releaseDeadline() {
            holdDeadline = false; deadlineWaiter?.resume(); deadlineWaiter = nil
        }
        func deadline(_ duration: Duration) async throws {
            if holdDeadline { await withCheckedContinuation { deadlineWaiter = $0 } }
            else { try await Task.sleep(for: duration) }
        }
        func drain(_ id: UUID) async {
            calls.append("drain")
            if holdDrain { await withCheckedContinuation { drainWaiter = $0 } }
            drainsReturned.append(id)
        }
        func mark(_ name: String) { calls.append(name) }
        func emit(_ buffer: LiveAudioBuffer, source: LiveSource) {
            outputs[source == .microphone ? 0 : 1].yield(buffer)
        }
        func precedes(_ first: String, _ second: String) -> Bool {
            guard let a = calls.firstIndex(of: first), let b = calls.firstIndex(of: second) else { return false }
            return a < b
        }
        func session(_ id: UUID, _ date: Date) -> CaptureSessionStore.Session {
            let root = URL(fileURLWithPath: "/tmp/prepared-capture/\(id)")
            return .init(id: id,startedAt: date,files: .init(directoryURL: root,
                manifestURL: root.appendingPathComponent("session.json"),captureBaseURL: root.appendingPathComponent("capture")))
        }
        func prepare(_ request: CaptureCoordinator.Request) -> CaptureLiveDerivative.Prepared? {
            calls.append("prepare"); stopAt("prepare")
            if nilPreparation { return nil }
            if let override { preparations.append(override); return override }
            let identity = LiveSessionIdentity(recordingID: request.id,captureSessionID: request.captureSessionID)
            let language: LiveASRConfiguration.Language = invalid == "language" ? .en : .init(rawValue: request.language.isEmpty ? "auto" : request.language) ?? .auto
            let model = invalid == "invalidBegin" ? "" : "fixture"
            let epochs = (bothSources ? [LiveSource.microphone,.system] : [.microphone]).map {
                LiveEpoch(id: UUID(),source: $0,engineRevision: model,language: language.rawValue,meetingOriginNanoseconds: nil)
            }
            let ingressIdentity = invalid == "ingressIdentity" ? LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID()) : identity
            let input = LiveSessionBegin(identity: ingressIdentity,configuration: .init(language: language,modelDirectory: "/fixture"),epochs: epochs)
            let ingress = request.liveIngress.flatMap { invalid == "existingConflict" ? nil : $0 }
                ?? LiveCaptureIngress(input: input,rawByteLimit: invalid == "ledgerBounds" ? 0 : 4 * 1024 * 1024)
            let binding = invalid == "sessionLedger" ? LiveCaptureIngress(input: ingress.input) : ingress
            let sessionIdentity = invalid == "sessionIdentity" ? LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID()) : identity
            let checked: (@MainActor @Sendable (CaptureLivePreview.Inputs) -> Bool)?
            if invalid == "unchecked" { checked = nil }
            else { checked = { inputs in
                self.calls.append("register"); self.registered.append(inputs); self.stopAt("register")
                return self.registrationAccepted
            } }
            let session = CaptureLiveDerivative.Session(identity: sessionIdentity,register: { _ in self.calls.append("legacy-register") },
                beginClosing: { self.closing.append(request.captureSessionID); self.calls.append("close"); self.reenter("close") },
                hardwareDidClose: { await self.drain(request.captureSessionID) },expire: { self.expired.append(request.captureSessionID) },
                pause: { self.calls.append("derivative-pause") },resume: { self.calls.append("derivative-resume") },
                inputDeviceChanged: { self.calls.append("derivative-device") },
                ingress: invalid == "unbound" ? nil : binding,
                registerPrepared: checked)
            let value = CaptureLiveDerivative.Prepared(ingress: ingress,session: session)
            preparations.append(value); return value
        }
        func make(_ request: CaptureCoordinator.Request) -> CaptureLiveDerivative.Session? {
            calls.append("make"); stopAt("make")
            guard legacySession else { return nil }
            let identity = invalid == "legacySessionIdentity" ? LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
                : .init(recordingID: request.id,captureSessionID: request.captureSessionID)
            return .init(identity: identity,
                register: { _ in self.calls.append("legacy-register") },
                beginClosing: { self.closing.append(request.captureSessionID); self.calls.append("close") },
                hardwareDidClose: { await self.drain(request.captureSessionID) },expire: {
                    self.expired.append(request.captureSessionID); self.stopAt("expire")
                })
        }
        func coordinator() -> CaptureCoordinator {
            let result = CaptureCoordinator(hardware: .init(start: { request,_ in
                self.hardwareRequests.append(request)
                try await self.step("hardware")
                let (mic,micOutput) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(4))
                let (system,systemOutput) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(4))
                self.outputs = [micOutput,systemOutput]
                return self.returnsStreams ? .init(mic: mic,system: system) : nil
            },stop: {
                self.calls.append("hardware-stop"); self.outputs.forEach { $0.finish() }; self.outputs = []
            },snapshot: { .init(duration: 4,microphoneEnabled: self.microphoneEnabled,systemAudioEnabled: self.systemEnabled) },
            pause: { self.calls.append("hardware-pause") },resume: { self.calls.append("hardware-resume") },
            switchInputDevice: { _ in self.calls.append("hardware-device") },bindEvents: { sink in
                if sink == nil { self.calls.append("unbind"); self.reenter("unbind") }
                else if self.stopPoint == "binding" {
                    self.calls.append("bind-status"); sink?(.status("binding-stop"))
                    self.calls.append("bind-returned")
                }
            }),persistence: .init(create: { id,date in
                try await self.step("create"); return await self.session(id,date)
            },began: { _,_ in try await self.step("began") },failedStart: { _,_,_ in await self.mark("failed") },
            stopped: { session,state,_ in
                await self.mark("checkpoint"); return .init(session: session,state: state,fileSize: 1,duration: 4)
            },termination: { _ in await self.mark("termination") },pauseResume: { _,_,_ in }),
            preview: .init(prepare: { _ in nil },make: {
                self.calls.append("apple-make"); self.stopAt("apple-make")
                return .init(start: { _,_ in await self.mark("apple") },stop: { await self.mark("apple-stop") })
            }),derivative: .init(prepare: { self.prepare($0) },make: { request,_ in self.make(request) }),
            derivativeDrainDeadline: .seconds(3),sleep: { try await self.deadline($0) },onEvent: { event in
                switch event {
                case .prepared(let request,_):
                    self.preparedRequests.append(request); self.events.append("prepared"); self.stopAt("prepared")
                case .started:
                    self.events.append("started"); self.calls.append("started"); self.stopAt("started")
                    if self.stopPoint == "controls" { self.owner?.pause(); try? self.owner?.switchInputDevice(to: "new") }
                case .liveBegan: self.events.append("liveBegan")
                case .liveEnded: self.events.append("liveEnded"); self.reenter("liveEnded")
                case .status(_,let message):
                    if message == nil { self.reenter("status") }
                    else if message == "binding-stop" { self.stopAt("binding") }
                    else if message == "Live transcription unavailable" { self.events.append("unavailable") }
                case .stopped: self.events.append("stopped")
                case .failed: self.events.append("failed")
                default: break
                }
            })
            owner = result; return result
        }
    }

    private func request(language: String = "nl", live: Bool = true) -> CaptureCoordinator.Request {
        let id = UUID()
        return .init(id: id,startedAt: Date(timeIntervalSince1970: 123),inputDeviceUID: "chosen",
            acousticEchoCancellation: false,echoSuppression: true,liveTranscription: live,language: language,
            associatedApp: "fixture",callBundleID: "fixture.call",showMiniPlayer: true,
            privacyScope: RecordingPrivacyScope(recordingID: id,pendingRootURL: URL(fileURLWithPath: "/tmp/prepared-privacy")))
    }
    private func eventually(_ predicate: () -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: TestTiming.asyncDeadline)
        while !predicate(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(2)) }
        return predicate()
    }
    private func asynchronously(_ predicate: () async -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: TestTiming.asyncDeadline)
        while ContinuousClock.now < end { if await predicate() { return true }; try? await Task.sleep(for: .milliseconds(2)) }
        return await predicate()
    }
    private func input(_ identity: LiveSessionIdentity, both: Bool = false,
                       language: LiveASRConfiguration.Language = .nl) -> LiveSessionBegin {
        .init(identity: identity,configuration: .init(language: language,modelDirectory: "/fixture"),
            epochs: (both ? [LiveSource.microphone,.system] : [.microphone]).map {
                .init(id: UUID(),source: $0,engineRevision: "fixture",language: language.rawValue,meetingOriginNanoseconds: nil)
            })
    }
    private func buffer(_ ingress: LiveCaptureIngress, source: LiveSource, rawEpoch: UUID) throws -> LiveAudioBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000,channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 16))
        pcm.frameLength = 16
        let samples = try #require(pcm.floatChannelData)
        for index in 0..<16 { samples[0][index] = 0.25 }
        let metadata = LiveAudioMetadata(sourceEpoch: rawEpoch,role: source == .microphone ? .mic : .system,timestamp: .unavailable,
            emittedFrames: .init(startFrame: 32,frameCount: 16,sampleRate: 16000),writeOutcome: .failed,converter: nil)
        let ticket = try #require(ingress.reserveRaw(source: source,metadata: metadata,frames: 16,rate: 16000,bytes: 64,format: format))
        return .init(pcm,metadata: metadata,ingress: ticket)
    }

    @Test(arguments: ["nl", ""])
    func preparedLedgerPrecedesHardwareAndPreservesFrozenRequest(language: String) async throws {
        let h = Harness(), c = h.coordinator(), original = request(language: language)
        try await c.start(original)
        await c.stop()
        let prepared = try #require(h.preparations.first), seen = try #require(h.hardwareRequests.first)
        #expect(seen.liveIngress === prepared.ingress && h.preparedRequests.first?.liveIngress === prepared.ingress)
        #expect(seen.id == original.id && seen.captureSessionID == original.captureSessionID && seen.startedAt == original.startedAt)
        #expect(seen.language == language && seen.inputDeviceUID == "chosen" && !seen.acousticEchoCancellation && seen.echoSuppression)
        #expect(seen.associatedApp == "fixture" && seen.callBundleID == "fixture.call" && seen.showMiniPlayer)
        #expect(seen.privacyScope?.recordingID == original.id && seen.privacyScope?.pendingReceiptURL == original.privacyScope?.pendingReceiptURL)
        #expect(h.registered.first?.language == (language.isEmpty ? "auto" : language))
        #expect(h.registered.first?.mic != nil && h.registered.first?.system == nil)
        #expect(h.calls.filter { $0 == "prepare" }.count == 1 && h.calls.filter { $0 == "register" }.count == 1)
        #expect(!h.calls.contains("make") && !h.calls.contains("legacy-register") && !h.calls.contains("apple"))
        #expect(h.precedes("prepare", "hardware"))
        #expect(h.precedes("began", "register"))
        #expect(h.precedes("register", "started"))
        #expect(h.events.filter { $0 == "liveBegan" }.count == 1 && h.events.filter { $0 == "liveEnded" }.count == 1)
    }

    @Test(arguments: [false,true])
    func nilPreparationRetainsLegacyOrApplePath(legacy: Bool) async throws {
        let h = Harness(), c = h.coordinator(); h.nilPreparation = true; h.legacySession = legacy
        try await c.start(request())
        if !legacy { #expect(await eventually { h.calls.contains("apple") }) }
        await c.stop()
        #expect(h.calls.filter { $0 == "make" }.count == 1)
        #expect(h.calls.contains("legacy-register") == legacy && !h.calls.contains("register"))
        #expect(h.hardwareRequests.first?.liveIngress == nil)
    }

    @Test func disabledLiveBypassesBothDerivativeFactories() async throws {
        let h = Harness(), c = h.coordinator()
        try await c.start(request(live: false)); await c.stop()
        #expect(!h.calls.contains("prepare") && !h.calls.contains("make") && !h.calls.contains("apple"))
    }

    @Test(arguments: ["sessionIdentity","ingressIdentity","sessionLedger","unbound","unchecked","language","ledgerBounds","invalidBegin","existingConflict"])
    func rejectedPreparationLeavesReturnedOwnersUntouched(reason: String) async throws {
        let h = Harness(), c = h.coordinator(); h.invalid = reason
        var original = request()
        if reason == "existingConflict" { original.liveIngress = LiveCaptureIngress(input: input(.init(recordingID: original.id,captureSessionID: original.captureSessionID))) }
        try await c.start(original); await c.stop()
        #expect(h.calls.contains("hardware") && h.events.contains("started") && h.events.contains("unavailable"))
        #expect(!h.events.contains("liveBegan") && !h.events.contains("liveEnded"))
        #expect(h.closing.isEmpty && h.expired.isEmpty && h.registered.isEmpty)
        #expect(!h.calls.contains("make") && !h.calls.contains("apple"))
        #expect(h.hardwareRequests.first?.liveIngress === original.liveIngress)
    }

    @Test func identicalAlreadySuppliedLedgerIsPreserved() async throws {
        let h = Harness(), c = h.coordinator()
        var original = request()
        original.liveIngress = LiveCaptureIngress(input: input(.init(recordingID: original.id,captureSessionID: original.captureSessionID)))
        try await c.start(original); await c.stop()
        #expect(h.hardwareRequests.first?.liveIngress === original.liveIngress)
        #expect(h.registered.count == 1 && h.expired.isEmpty)
    }

    @Test(arguments: ["sources","zero","nil","rejected"])
    func actualRegistrationFailurePreservesCaptureWithoutFallback(reason: String) async throws {
        let h = Harness(), c = h.coordinator()
        h.bothSources = reason == "sources"; h.microphoneEnabled = reason != "zero"
        h.returnsStreams = reason != "nil"; h.registrationAccepted = reason != "rejected"
        let original = request(); try await c.start(original); await c.stop()
        #expect(h.events.contains("started") && h.events.contains("stopped") && h.events.contains("unavailable"))
        #expect(!h.events.contains("liveBegan") && !h.events.contains("liveEnded"))
        #expect(h.expired == [original.captureSessionID])
        #expect(h.registered.count == (reason == "rejected" ? 1 : 0))
        #expect(!h.calls.contains("make") && !h.calls.contains("apple"))
    }

    @Test(arguments: ["prepare","prepared","register","started","make"])
    func directCallbackStopOwnsCleanupAndPreventsLatePublication(point: String) async throws {
        let h = Harness(), c = h.coordinator(); h.stopPoint = point
        if point == "make" { h.nilPreparation = true; h.legacySession = true }
        let original = request(); try await c.start(original); await c.stop()
        #expect(h.observedSynchronousStop && !c.isBusy)
        #expect(h.closing == [original.captureSessionID] && h.calls.filter { $0 == "drain" }.count == 1)
        #expect(!h.events.contains("liveBegan") && !h.events.contains("liveEnded"))
        if point == "prepare" || point == "prepared" { #expect(!h.calls.contains("hardware") && !h.calls.contains("register")) }
        if point == "register" { #expect(!h.events.contains("started")) }
        if point == "started" { #expect(h.registered.count == 1) }
    }

    @Test(arguments: ["close","unbind","status","liveEnded"])
    func synchronousStopReentryUsesOneTerminalOwner(point: String) async throws {
        let h = Harness(), c = h.coordinator(); h.reentryPoint = point
        let original = request(); try await c.start(original)
        c.requestStop(); await c.stop()
        #expect(h.reentries == 1 && c.isTerminating && c.isBusy)
        #expect(c.recordingID == nil && !c.isStopping)
        #expect(h.closing == [original.captureSessionID])
        for name in ["hardware-stop","drain","checkpoint"] { #expect(h.calls.filter { $0 == name }.count == 1) }
        #expect(h.events.filter { $0 == "liveEnded" }.count == 1 && h.events.filter { $0 == "stopped" }.count == 1)
        await #expect(throws: CaptureCoordinator.Failure.self) { try await c.start(request()) }
    }

    @Test func legacyMakeStopLeavesForeignSuppliedIngressUntouched() async throws {
        let h = Harness(), c = h.coordinator()
        h.nilPreparation = true; h.legacySession = true; h.stopPoint = "make"
        var original = request()
        let foreign = LiveCaptureIngress(input: input(.init(recordingID: UUID(),captureSessionID: UUID())))
        original.liveIngress = foreign
        try await c.start(original); await c.stop()
        #expect(h.observedSynchronousStop && c.recordingID == nil)
        #expect(foreign.pauseAdmission(source: .microphone) != nil)
        #expect(h.closing == [original.captureSessionID] && h.expired.isEmpty)
        #expect(!h.calls.contains("legacy-register") && !h.events.contains("liveBegan"))
    }

    @Test func synchronousBindingStatusStopPreventsHardwareDispatch() async throws {
        let h = Harness(), c = h.coordinator(); h.stopPoint = "binding"
        let original = request(); try await c.start(original); await c.stop()
        #expect(h.observedSynchronousStop && h.calls.contains("bind-returned"))
        #expect(!h.calls.contains("hardware") && !h.calls.contains("hardware-stop"))
        #expect(h.closing == [original.captureSessionID] && h.calls.filter { $0 == "drain" }.count == 1)
        #expect(h.registered.isEmpty && h.calls.filter { $0 == "checkpoint" }.count == 1)
        #expect(!h.events.contains("started") && !h.events.contains("liveBegan") && !c.isBusy)
    }

    @Test func lateAppleFactoryStopRetainsCleanupWithoutPublication() async throws {
        let h = Harness(), c = h.coordinator(); h.nilPreparation = true; h.stopPoint = "apple-make"
        try await c.start(request()); await c.stop()
        #expect(h.observedSynchronousStop && !c.isBusy)
        #expect(h.calls.filter { $0 == "apple-make" }.count == 1)
        #expect(h.calls.filter { $0 == "apple-stop" }.count == 1 && !h.calls.contains("apple"))
        #expect(!h.events.contains("liveBegan") && !h.events.contains("liveEnded"))
        #expect(h.calls.filter { $0 == "checkpoint" }.count == 1)
    }

    @Test(arguments: ["make","expire"])
    func rejectedLegacyFactoryStopCannotPublishUnavailableAfterTerminal(point: String) async throws {
        let h = Harness(), c = h.coordinator()
        h.nilPreparation = true; h.legacySession = true; h.invalid = "legacySessionIdentity"; h.stopPoint = point
        let original = request(); try await c.start(original); await c.stop()
        #expect(h.observedSynchronousStop && c.recordingID == nil)
        #expect(h.expired == [original.captureSessionID])
        #expect(!h.events.contains("unavailable") && !h.events.contains("liveBegan") && !h.events.contains("liveEnded"))
    }

    @Test(arguments: ["create","hardware","began"])
    func heldStartupStopRemainsIndependentOfPreparedRegistration(step: String) async throws {
        let h = Harness(), c = h.coordinator(); h.hold = step
        let start = Task { try await c.start(request()) }
        let arrived = await eventually { h.waiter != nil }
        #expect(arrived)
        c.requestStop(); #expect(c.isStopping)
        if step != "create" { #expect(h.closing.count == 1) }
        h.release(); _ = await start.result; await c.stop()
        #expect(!c.isBusy && h.registered.isEmpty)
        #expect(h.calls.filter { $0 == "prepare" }.count == (step == "create" ? 0 : 1))
        #expect(!h.events.contains("liveBegan") && !h.events.contains("liveEnded"))
        if step != "create" { #expect(h.precedes("close", "hardware-stop")) }
    }

    @Test(arguments: ["hardware","began"])
    func startupFailureDrainsAdoptedOwnerWithoutLiveEvents(step: String) async throws {
        let h = Harness(), c = h.coordinator(); h.failure = step
        let original = request(); let result = await Task { try await c.start(original) }.result
        if case .success = result { Issue.record("Expected injected startup failure") }
        #expect(h.closing == [original.captureSessionID] && h.calls.contains("drain") && h.calls.contains("failed"))
        #expect(h.registered.isEmpty && !h.events.contains("liveBegan") && !h.events.contains("liveEnded") && !c.isBusy)
    }

    @Test func controlsFromStartedTargetAlreadyRegisteredPreparedOwner() async throws {
        let h = Harness(), c = h.coordinator(); h.stopPoint = "controls"
        try await c.start(request()); try c.resume(); await c.stop()
        #expect(h.calls.contains("derivative-pause") && h.calls.contains("derivative-device") && h.calls.contains("derivative-resume"))
        #expect(h.precedes("register", "derivative-pause"))
        let before = h.calls
        c.pause(); try c.resume(); try c.switchInputDevice(to: "late")
        #expect(h.calls == before)
    }

    @Test func deadlineExpiresOnlyOldPreparedOwnerAndNewCaptureRemainsIndependent() async throws {
        let h = Harness(), c = h.coordinator(); h.holdDrain = true; h.holdDeadline = true
        defer { h.release() }
        let old = request(); try await c.start(old)
        let stop = Task { await c.stop(); h.calls.append("stop-returned") }
        #expect(await eventually { h.drainWaiter != nil && h.deadlineWaiter != nil })
        h.releaseDeadline()
        #expect(await eventually { h.calls.contains("stop-returned") })
        await stop.value
        #expect(h.expired == [old.captureSessionID] && h.drainWaiter != nil && !c.isBusy)
        h.holdDrain = false
        let fresh = request(); try await c.start(fresh); await c.stop()
        #expect(h.preparations.last?.session.identity.captureSessionID == fresh.captureSessionID)
        #expect(!h.expired.contains(fresh.captureSessionID))
        #expect(h.drainWaiter != nil && !h.drainsReturned.contains(old.captureSessionID))
        #expect(h.drainsReturned.contains(fresh.captureSessionID))
        h.release()
        #expect(await eventually { h.drainsReturned.contains(old.captureSessionID) })
    }

    @Test func realAdapterRejectsSameIdentityLedgerPairingWithoutTouchingForeignOwner() async throws {
        let original = request(), h = Harness(), c = h.coordinator(), native = PreparationNativeFixture()
        let begin = input(.init(recordingID: original.id,captureSessionID: original.captureSessionID))
        let a = LiveCaptureIngress(input: begin), b = LiveCaptureIngress(input: begin), store = LiveTranscriptStore(identity: begin.identity)
        let core = LiveCaptureSessionCoordinator(input: begin,store: store,transport: native.transport,ingress: a)
        let actual = try LiveCaptureStreamSession(input: begin,ingress: a,coordinator: core)
        defer { actual.expire() }
        let exported = actual.derivativeSession()
        #expect(exported.ingress === a && exported.registerPrepared != nil)
        h.override = .init(ingress: b,session: exported)
        try await c.start(original); await c.stop()
        #expect(h.events.contains("unavailable") && !h.events.contains("liveBegan"))
        #expect(await native.begins == 0)
        #expect(!(await store.projection()).isClosed)
        #expect(a.pauseAdmission(source: .microphone) != nil && b.pauseAdmission(source: .microphone) != nil)
        actual.expire(); try await core.waitUntilClosed()
    }

    @Test func realAdapterSourceMismatchClosesWithoutNativeBeginOrLiveBegan() async throws {
        let original = request(), h = Harness(), c = h.coordinator(), native = PreparationNativeFixture()
        let begin = input(.init(recordingID: original.id,captureSessionID: original.captureSessionID),both: true)
        let ingress = LiveCaptureIngress(input: begin), store = LiveTranscriptStore(identity: begin.identity)
        let core = LiveCaptureSessionCoordinator(input: begin,store: store,transport: native.transport,ingress: ingress)
        let actual = try LiveCaptureStreamSession(input: begin,ingress: ingress,coordinator: core)
        defer { actual.expire() }
        h.override = .init(ingress: ingress,session: actual.derivativeSession())
        try await c.start(original); await c.stop()
        #expect(h.events.contains("started") && h.events.contains("stopped") && h.events.contains("unavailable"))
        #expect(!h.events.contains("liveBegan"))
        #expect(await native.begins == 0)
        #expect((await store.projection()).isClosed)
    }

    @Test func realTwoSourcePreparationRetainsOriginalRawFactsBeforeNativeReadiness() async throws {
        let original = request(language: ""), h = Harness(), c = h.coordinator(), native = PreparationNativeFixture()
        let begin = input(.init(recordingID: original.id,captureSessionID: original.captureSessionID),both: true,language: .auto)
        let ingress = LiveCaptureIngress(input: begin), store = LiveTranscriptStore(identity: begin.identity)
        let core = LiveCaptureSessionCoordinator(input: begin,store: store,transport: native.transport,ingress: ingress)
        let actual = try LiveCaptureStreamSession(input: begin,ingress: ingress,coordinator: core)
        let micEpoch = UUID(), systemEpoch = UUID()
        var mic: LiveAudioBuffer? = try buffer(ingress,source: .microphone,rawEpoch: micEpoch)
        var system: LiveAudioBuffer? = try buffer(ingress,source: .system,rawEpoch: systemEpoch)
        await native.setHoldBegin()
        h.systemEnabled = true; h.hold = "began"
        h.override = .init(ingress: ingress,session: actual.derivativeSession())
        defer { h.release(); actual.expire() }
        let start = Task { try await c.start(original) }
        let beganHeld = await eventually { h.waiter != nil }
        #expect(beganHeld)
        if beganHeld {
            #expect(h.hardwareRequests.first?.liveIngress === ingress)
            #expect(await native.begins == 0)
            #expect(!h.events.contains("started") && !h.events.contains("liveBegan"))
            if let mic { h.emit(mic,source: .microphone) }
            if let system { h.emit(system,source: .system) }
        }
        h.release()
        let started = await start.result
        do { try started.get() }
        catch {
            actual.expire(); await native.release(); await c.stop()
            if await native.begins > 0 { #expect(await asynchronously { await native.beginReturned }) }
            #expect(await asynchronously { await native.shutdownReturned })
            throw error
        }
        let loading = await asynchronously { await native.beginWaiter != nil }
        #expect(loading && h.events.contains("liveBegan"))
        let losses = await asynchronously {
            let projection = await store.projection()
            return projection.captureLosses.contains { $0.source == .microphone && $0.sourceEpoch == micEpoch && $0.frames?.startFrame == 32 && $0.frames?.frameCount == 16 && $0.reason == .preparation }
                && projection.captureLosses.contains { $0.source == .system && $0.sourceEpoch == systemEpoch && $0.frames?.startFrame == 32 && $0.frames?.frameCount == 16 && $0.reason == .preparation }
        }
        #expect(losses)
        #expect(await native.beginInputs.first?.configuration.language == .auto)
        #expect(await native.beginInputs.first?.epochs.map(\.source) == [.microphone,.system])
        #expect(ingress.statistics(.microphone).rawBytes == 64 && ingress.statistics(.system).rawBytes == 64)
        mic = nil; system = nil
        #expect(await eventually { ingress.statistics(.microphone).rawBytes == 0 && ingress.statistics(.system).rawBytes == 0 })
        actual.expire(); await native.release(); await c.stop()
        #expect(await asynchronously { await native.beginReturned })
        #expect(await asynchronously { await native.shutdownReturned })
        #expect((await store.projection()).isClosed && c.recordingID == nil)
    }

    @Test(arguments: [false,true])
    func neverRegisteredRawLossAndResourceOwnershipSurviveCleanClosure(foreign: Bool) async throws {
        let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID()), begin = input(identity)
        let profile = LiveResourceProfile(id: "fixture",hardware: "fixture-mac",modelRevision: "fixture",chunkMs: 1120,sourceCount: 1,
            qualificationID: "test-only",asrBytes: 400,attributionBytes: nil,headroomBytes: 100,concurrentChatModels: [:],backgroundWorkQualified: false)
        let policy = LiveModelResourcePolicy(profiles: [profile])
        let leaseIdentity = foreign ? LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID()) : identity
        let lease = try await policy.admit(identity: leaseIdentity,request: .init(profileID: "fixture",hardware: "fixture-mac",modelRevision: "fixture",
            chunkMs: 1120,sourceCount: 1,attributionRequested: false),measurement: .init(availableBytes: 1000,pressure: .normal))
        let native = PreparationNativeFixture(); await native.setHoldShutdown()
        let ingress = LiveCaptureIngress(input: begin), store = LiveTranscriptStore(identity: identity)
        let core = LiveCaptureSessionCoordinator(input: begin,store: store,transport: native.transport,resources: policy,lease: lease,ingress: ingress)
        let actual = try LiveCaptureStreamSession(input: begin,ingress: ingress,coordinator: core)
        let rawEpoch = UUID()
        let metadata = LiveAudioMetadata(sourceEpoch: rawEpoch,role: .mic,timestamp: .unavailable,
            emittedFrames: .init(startFrame: 32,frameCount: 16,sampleRate: 16000),writeOutcome: .failed,converter: nil)
        var carrier: LiveCaptureIngress.RawReservation? = try #require(ingress.reserveRaw(source: .microphone,metadata: metadata,frames: 16,rate: 16000,bytes: 64))
        let close = Task { try await actual.hardwareDidClose() }
        // A missing clean path must fail boundedly and still release every held task.
        let closed = await asynchronously { (await store.projection()).isClosed }
        #expect(closed)
        if !closed { actual.expire() }
        _ = await close.result
        #expect(await asynchronously { await native.shutdownWaiter != nil })
        let projection = await store.projection()
        #expect(projection.isClosed && projection.lanes.isEmpty && projection.segments.isEmpty)
        #expect(projection.captureLosses.contains { $0.source == .microphone && $0.sourceEpoch == rawEpoch && $0.frames?.startFrame == 32 && $0.frames?.frameCount == 16 && $0.reason == .stopped })
        #expect(await native.begins == 0)
        #expect(ingress.statistics(.microphone).rawBytes == 64)
        #expect(await policy.reservedBytes == 400)
        withExtendedLifetime(carrier) { #expect(ingress.statistics(.microphone).rawBytes == 64) }
        carrier = nil
        #expect(ingress.statistics(.microphone).rawBytes == 0)
        await native.release()
        #expect(await asynchronously { await native.shutdownReturned })
        #expect(await asynchronously { await policy.reservedBytes == (foreign ? 400 : 0) })
        #expect(await policy.validateActiveLease(lease) == foreign)
        if foreign { await policy.release(lease) }
    }
}
