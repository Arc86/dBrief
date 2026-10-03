import AVFoundation
import Foundation
import Testing
import dBriefWire
@testable import dBrief

private actor StreamNativeFixture {
    let input: LiveSessionBegin
    let stream: AsyncThrowingStream<LiveSessionEvent, Error>
    let output: AsyncThrowingStream<LiveSessionEvent, Error>.Continuation
    var requests: [LiveSessionRequest] = []
    var begins = 0
    var shutdowns = 0
    var holdBegin = false
    var holdReplacement = false
    var holdReplacementReady = false
    var holdSystemFinish = false
    var holdShutdown = false
    var holdBarrier = false
    var barrierWaiter: CheckedContinuation<Void, Never>?
    var consumeMicrophone = true
    var beginWaiter: CheckedContinuation<Void, Never>?
    var replacementWaiter: CheckedContinuation<Void, Never>?
    var systemFinishWaiter: CheckedContinuation<Void, Never>?
    var shutdownWaiter: CheckedContinuation<Void, Never>?
    var epochs: [LiveSource: LiveEpoch] = [:]
    var sequences: [LiveSource: UInt64] = [:]
    var ends: [LiveSource: Int64] = [:]
    var settled: [LiveSource: Int64] = [:]
    var segmentIndexes: [LiveSource: UInt64] = [:]
    var packetSequences: [LiveSource: UInt64] = [:]
    var closed: Set<LiveSource> = []
    init(_ input: LiveSessionBegin) {
        self.input = input
        (stream,output) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(128))
    }
    func emit(_ source: LiveSource, _ payload: LiveLaneEvent.Payload) {
        guard let epoch = epochs[source] else { return }
        let sequence = sequences[source] ?? 0; sequences[source] = sequence + 1
        output.yield(.lane(.init(scope: .init(identity: input.identity,source: source,epochID: epoch.id),sequence: sequence,payload: payload)))
    }
    func begin() async -> AsyncThrowingStream<LiveSessionEvent, Error> {
        begins += 1
        if holdBegin { await withCheckedContinuation { beginWaiter = $0 } }
        for epoch in input.epochs {
            epochs[epoch.source] = epoch
            emit(epoch.source,.ready(generation: UUID(),originSample: 0))
        }
        return stream
    }
    func command(_ request: LiveSessionRequest) async -> LiveSessionReply {
        requests.append(request)
        switch request {
        case .packet(let packet):
            guard epochs[packet.scope.source]?.id == packet.scope.epochID else { return .rejected(.staleScope) }
            guard packet.sequence == (packetSequences[packet.scope.source] ?? 0), packet.startSample == (ends[packet.scope.source] ?? 0) else { return .rejected(.outOfOrder) }
            packetSequences[packet.scope.source] = packet.sequence + 1
            let end = packet.startSample + Int64(packet.sampleCount)
            let consumed = packet.scope.source == .microphone && !consumeMicrophone ? Int64(0) : end
            ends[packet.scope.source] = end
            emit(packet.scope.source,.admitted(packetSequence: packet.sequence,sampleEnd: end))
            emit(packet.scope.source,.progress(.init(capturedSampleEnd: end,admittedSampleEnd: end,
                consumedSampleEnd: consumed,queuedSamples: 0,inFlightSamples: 0,heldSamples: end - consumed,
                creditSamples: Int64(input.configuration.pendingSampleLimit) - (end - consumed))))
        case .barrier(let barrier):
            let source = barrier.scope.source
            guard epochs[source]?.id == barrier.scope.epochID else { return .rejected(.staleScope) }
            guard barrier.sampleEnd == (ends[source] ?? 0), barrier.nextPacketSequence == (packetSequences[source] ?? 0) else { return .rejected(.outOfOrder) }
            if barrier.kind == .finish || barrier.kind == .utterance || barrier.kind == .pause {
                if holdBarrier { await withCheckedContinuation { barrierWaiter = $0 } }
                if barrier.kind == .finish && source == .system && holdSystemFinish { await withCheckedContinuation { systemFinishWaiter = $0 } }
                let start = settled[source] ?? 0
                if barrier.sampleEnd > start {
                    let index = segmentIndexes[source] ?? 0; segmentIndexes[source] = index + 1
                    emit(source,.committed(.init(id: .init(epochID: barrier.scope.epochID,index: index),source: source,
                        range: .init(samples: .init(start: start,end: barrier.sampleEnd),meeting: nil),text: "Fixture closing evidence")))
                }
                settled[source] = barrier.sampleEnd
                emit(source,.barrierCompleted(requestID: UUID(),kind: barrier.kind,sampleEnd: barrier.sampleEnd))
                if barrier.kind == .finish {
                    emit(source,.closed(sampleEnd: barrier.sampleEnd)); closed.insert(source)
                    if closed.count == input.epochs.count { output.yield(.finished(input.identity)) }
                } else if barrier.kind == .utterance { emit(source,.ready(generation: UUID(),originSample: barrier.sampleEnd)) }
                else { emit(source,.progress(.init(capturedSampleEnd: barrier.sampleEnd,admittedSampleEnd: barrier.sampleEnd,
                    consumedSampleEnd: barrier.sampleEnd,queuedSamples: 0,inFlightSamples: 0,heldSamples: 0,creditSamples: 0))) }
            }
        case .replaceEpoch(_,_,let epoch):
            if holdReplacement { await withCheckedContinuation { replacementWaiter = $0 } }
            epochs[epoch.source] = epoch; sequences[epoch.source] = 0; ends[epoch.source] = 0
            settled[epoch.source] = 0; segmentIndexes[epoch.source] = 0
            packetSequences[epoch.source] = 0
            if !holdReplacementReady { emit(epoch.source,.ready(generation: UUID(),originSample: 0)) }
        case .cut(let scope,let sequence,let end,_):
            guard epochs[scope.source]?.id == scope.epochID else { return .rejected(.staleScope) }
            ends[scope.source] = end; packetSequences[scope.source] = sequence
        default: break
        }
        return .accepted
    }
    func configure(begin: Bool = false, replacement: Bool = false, systemFinish: Bool = false,
                   shutdown: Bool = false, consumeMicrophone: Bool = true, barrier: Bool = false, replacementReady: Bool = false) {
        holdBegin = begin; holdReplacement = replacement; holdSystemFinish = systemFinish
        holdShutdown = shutdown; self.consumeMicrophone = consumeMicrophone
        holdBarrier = barrier
        holdReplacementReady = replacementReady
    }
    func releaseBarrier() { holdBarrier = false; barrierWaiter?.resume(); barrierWaiter = nil }
    func release() { holdBegin = false; holdReplacement = false; beginWaiter?.resume(); beginWaiter = nil; replacementWaiter?.resume(); replacementWaiter = nil }
    func releaseReplacement() { holdReplacement = false; replacementWaiter?.resume(); replacementWaiter = nil }
    func releaseReplacementReady() {
        holdReplacementReady = false
        for source in epochs.keys { emit(source,.ready(generation: UUID(),originSample: settled[source] ?? 0)) }
    }
    func releaseSystemFinish() { holdSystemFinish = false; systemFinishWaiter?.resume(); systemFinishWaiter = nil }
    func releaseShutdown() { holdShutdown = false; shutdownWaiter?.resume(); shutdownWaiter = nil }
    func shutdown() async {
        shutdowns += 1
        if holdShutdown { await withCheckedContinuation { shutdownWaiter = $0 } }
    }
    func transport() -> LiveASRTransport {
        .init(begin: { _ in await self.begin() },command: { await self.command($0) },deadline: { _ in },shutdown: { await self.shutdown() })
    }
    var packets: [LiveAudioPacket] { requests.compactMap { if case .packet(let packet) = $0 { return packet }; return nil } }
    var barriers: [LiveFinishBarrier] { requests.compactMap { if case .barrier(let barrier) = $0 { return barrier }; return nil } }
    var replacements: [LiveEpoch] { requests.compactMap { if case .replaceEpoch(_,_,let epoch) = $0 { return epoch }; return nil } }
}

private struct StreamFixture {
    let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
    let rawEpoch = UUID()
    func input(both: Bool = false, origin: Int64? = nil) -> LiveSessionBegin {
        .init(identity: identity,configuration: .init(language: .auto,modelDirectory: "/fixture"),
            epochs: (both ? [LiveSource.microphone,.system] : [.microphone]).map {
                .init(id: UUID(),source: $0,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: origin)
            })
    }
    func buffer(_ pool: LiveCaptureIngress, source: LiveSource = .microphone, frames: Int = 4800,
                rate: Double = 48000, start: Int = 0, closingTail: Bool = false) throws -> LiveAudioBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate,channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { buffer.floatChannelData![0][index] = 0.25 }
        let metadata = LiveAudioMetadata(sourceEpoch: rawEpoch,role: source == .microphone ? .mic : .system,timestamp: .unavailable,
            emittedFrames: .init(startFrame: Int64(start),frameCount: Int64(frames),sampleRate: rate),writeOutcome: .failed,converter: nil)
        let ticket = try #require(pool.reserveRaw(source: source,metadata: metadata,frames: frames,rate: rate,bytes: frames*4,closingTail: closingTail,format: format))
        return .init(buffer,metadata: metadata,ingress: ticket)
    }
}

private func streamEventually(_ predicate: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<300 { if await predicate() { return true }; try? await Task.sleep(for: .milliseconds(2)) }
    return false
}

private actor StreamDeadlineFixture {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0
    private(set) var handled = 0
    private(set) var cancelled = 0
    func wait() async {
        entered += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append($0) }
        } onCancel: { Task { await self.didCancel() } }
    }
    private func didCancel() { cancelled += 1 }
    func didHandle() { handled += 1 }
    func fireNext() { guard !waiters.isEmpty else { return }; waiters.removeFirst().resume() }
}

@Suite struct LiveCaptureStreamSessionTests {
    @MainActor @Test func registeredPauseWaitsForLateReservedInputAndRealEOFTailBeforeFreshUnalignedResume() async throws {
        let f = StreamFixture(), input = f.input(origin: 1_000_000_000), pool = LiveCaptureIngress(input: input)
        let native = StreamNativeFixture(input), store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core,retryInterval: .milliseconds(2))
        let derivative = session.derivativeSession()
        let (stream,output) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: stream,system: nil,language: "auto")))
        try #require(await streamEventually { await core.readySources.count == 1 })
        output.yield(try f.buffer(pool))
        try #require(await streamEventually { await native.packets.count == 1 })
        let late = try f.buffer(pool,start: 4800)
        derivative.pause()
        #expect(await native.barriers.isEmpty)
        output.yield(late)
        try #require(await streamEventually { await core.pausedSources == [.microphone] })
        let paused = try #require(await native.barriers.last)
        #expect(paused.kind == .pause && paused.sampleEnd == 3200)
        #expect(await store.projection().segments.first?.range.samples == .init(start: 0,end: 3200))
        derivative.resume()
        try #require(await streamEventually {
            let replacements = await native.replacements.count, ready = await core.readySources.count
            return replacements == 1 && ready == 1 && !pool.isAdmissionPaused(.microphone)
        })
        let fresh = try #require(await native.replacements.first)
        #expect(fresh.id != input.epochs[0].id && fresh.meetingOriginNanoseconds == nil)
        output.yield(try f.buffer(pool,start: 9600))
        try #require(await streamEventually { await native.packets.contains { $0.scope.epochID == fresh.id } })
        session.beginClosing(); output.finish(); try await session.hardwareDidClose()
        let display = await store.projection()
        #expect(display.isClosed && display.segments.count == 2)
        #expect(display.segments.last?.range.samples == .init(start: 0,end: 1600))
        #expect(display.segments.last?.range.meeting == nil)
        #expect(await native.barriers.map(\.kind) == [.pause,.finish])
    }

    @MainActor @Test func idleRegisteredPauseWakesWithoutAudioAndStopClosesItsSettledPrefix() async throws {
        let f = StreamFixture(), input = f.input(), pool = LiveCaptureIngress(input: input)
        let native = StreamNativeFixture(input), store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core,retryInterval: .milliseconds(2))
        let derivative = session.derivativeSession()
        let (stream,output) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: stream,system: nil,language: "auto")))
        try #require(await streamEventually { await core.readySources.count == 1 })
        derivative.pause(); derivative.pause()
        try #require(await streamEventually { await core.pausedSources == [.microphone] })
        session.beginClosing(); output.finish(); try await session.hardwareDidClose()
        #expect(await native.barriers.map(\.kind) == [.pause,.finish])
        #expect(await native.barriers.allSatisfy { $0.sampleEnd == 0 && $0.nextPacketSequence == 0 })
        #expect(await native.replacements.isEmpty)
        #expect(await store.projection().isClosed)
    }

    @MainActor @Test func pauseDuringHeldResumeKeepsFreshEpochFrozenAndLateStopCannotReopenIt() async throws {
        let f = StreamFixture(), input = f.input(), pool = LiveCaptureIngress(input: input)
        let native = StreamNativeFixture(input), store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core,retryInterval: .milliseconds(2))
        let derivative = session.derivativeSession()
        let (stream,output) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: stream,system: nil,language: "auto")))
        try #require(await streamEventually { await core.readySources.count == 1 })
        derivative.pause()
        try #require(await streamEventually { await core.pausedSources == [.microphone] })
        await native.configure(replacement: true)
        derivative.resume()
        try #require(await streamEventually { await native.replacementWaiter != nil })
        derivative.pause()
        await native.releaseReplacement()
        try #require(await streamEventually { await native.barriers.filter { $0.kind == .pause }.count == 2 })
        #expect(await native.packets.isEmpty)
        let fresh = try #require(await native.replacements.first)
        #expect(await native.barriers.last?.scope.epochID == fresh.id)
        let token = try #require(pool.pauseAdmission(source: .microphone))
        #expect(token.scope.epochID == fresh.id && pool.canSealPause(token,scope: token.scope))
        session.beginClosing(); derivative.resume(); output.finish(); try await session.hardwareDidClose()
        #expect(await native.replacements.count == 1)
        #expect(await native.barriers.last?.kind == .finish)
        #expect(await store.projection().isClosed)
    }

    @MainActor @Test(arguments: [false,true]) func heldResumeDeadlineKeepsAdmissionFrozenAndNeverAdoptsLateReadiness(holdReady: Bool) async throws {
        let f = StreamFixture(), input = f.input(origin: 1_000_000_000), pool = LiveCaptureIngress(input: input)
        let native = StreamNativeFixture(input), store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let clock = StreamDeadlineFixture()
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core,
            retryInterval: .milliseconds(2),deadlineSleep: { _ in await clock.wait() },deadlineHandled: { await clock.didHandle() })
        let derivative = session.derivativeSession()
        let (stream,output) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: stream,system: nil,language: "auto")))
        try #require(await streamEventually { await core.readySources.count == 1 })
        derivative.pause()
        try #require(await streamEventually { await core.pausedSources == [.microphone] })
        try #require(await streamEventually { await clock.entered == 1 })
        // Coordinator Pause settlement can precede the stream driver's timer
        // retirement. Resume needs that actual cancellation, not just paused UI.
        try #require(await streamEventually { await clock.cancelled == 1 })
        await native.configure(replacement: !holdReady,replacementReady: holdReady)
        derivative.resume()
        if holdReady {
            try #require(await streamEventually {
                let fresh = await native.replacements.first, lane = await core.streamState(source: .microphone)
                return fresh != nil && lane?.epoch.id == fresh?.id && lane?.ready == false
            })
        } else { try #require(await streamEventually { await native.replacementWaiter != nil }) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000,channels: 1))
        let metadata = LiveAudioMetadata(sourceEpoch: f.rawEpoch,role: .mic,timestamp: .unavailable,
            emittedFrames: .init(startFrame: 0,frameCount: 16,sampleRate: 16000),writeOutcome: .failed,converter: nil)
        #expect(pool.reserveRaw(source: .microphone,metadata: metadata,frames: 16,rate: 16000,bytes: 64,format: format) == nil)
        // First fire only the cancelled Pause timer. The held resume owner must
        // remain available; a stale timer cannot stand in for its real deadline.
        await clock.fireNext()
        try #require(await streamEventually { await clock.handled == 1 })
        #expect(await core.streamState(source: .microphone)?.gapReason != .unavailable)
        #expect(pool.isAdmissionPaused(.microphone))
        #expect(!(await store.projection().isClosed))
        try #require(await streamEventually { await clock.entered == 2 })
        await clock.fireNext()
        try #require(await streamEventually { await core.streamState(source: .microphone)?.gapReason == .unavailable })
        await native.releaseReplacement(); if holdReady { await native.releaseReplacementReady() }
        session.beginClosing(); output.finish(); try await session.hardwareDidClose()
        let display = await store.projection()
        #expect(display.isClosed && display.segments.isEmpty)
        #expect(display.captureLosses.contains { $0.reason == .preparation && $0.frames?.startFrame == 0 })
        #expect(await native.packets.isEmpty)
        #expect(await native.replacements.count == 1)
    }

    @MainActor @Test func inputDeviceHookRetiresRealMicrophoneConverterBeforeReplacementAndKeepsSystemContinuity() async throws {
        let f = StreamFixture(), input = f.input(both: true), pool = LiveCaptureIngress(input: input)
        let native = StreamNativeFixture(input), store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core,retryInterval: .milliseconds(2))
        let derivative = session.derivativeSession()
        let (mic,micOut) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let (system,systemOut) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: mic,system: system,language: "auto")))
        try #require(await streamEventually { await core.readySources.count == 2 })
        micOut.yield(try f.buffer(pool)); systemOut.yield(try f.buffer(pool,source: .system))
        try #require(await streamEventually { await native.packets.count == 2 })
        derivative.inputDeviceChanged()
        try #require(await streamEventually { await native.replacements.count == 1 })
        let fresh = try #require(await native.replacements.first)
        try #require(await streamEventually { await core.readySources.count == 2 })
        #expect(fresh.source == .microphone && fresh.meetingOriginNanoseconds == nil)
        // Even a fixture reusing the raw epoch cannot rebind the old converter
        // across the explicit device hook. New microphone EOF is exactly1600.
        micOut.yield(try f.buffer(pool,start: 4800)); systemOut.yield(try f.buffer(pool,source: .system,start: 4800))
        try #require(await streamEventually { await native.packets.count == 4 })
        session.beginClosing(); micOut.finish(); systemOut.finish(); try await session.hardwareDidClose()
        let display = await store.projection()
        #expect(display.segments.first { $0.source == .microphone }?.range.samples == .init(start: 0,end: 1600))
        #expect(display.segments.first { $0.source == .system }?.range.samples == .init(start: 0,end: 3200))
        #expect(display.captureLosses.contains { $0.source == .microphone && $0.reason == .deviceInterruption })
        #expect(!display.captureLosses.contains { $0.source == .system })
        #expect(await native.replacements.count == 1)
    }

    @MainActor @Test func acceptedRecoveryWaitsForNewPauseRawDrainWithoutClosingHealthySystemSource() async throws {
        let f = StreamFixture(), input = f.input(both: true), pool = LiveCaptureIngress(input: input)
        let native = StreamNativeFixture(input), store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core,retryInterval: .milliseconds(2))
        let derivative = session.derivativeSession()
        let (mic,micOut) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let (system,systemOut) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: mic,system: system,language: "auto")))
        try #require(await streamEventually { await core.readySources.count == 2 })
        micOut.yield(try f.buffer(pool)); systemOut.yield(try f.buffer(pool,source: .system))
        try #require(await streamEventually { await native.packets.count == 2 })
        await native.configure(replacement: true)
        derivative.inputDeviceChanged()
        try #require(await streamEventually { await native.replacementWaiter != nil })
        let late = try f.buffer(pool,start: 4800)
        derivative.pause()
        let boundary = try #require(pool.pauseAdmission(source: .microphone))
        #expect(pool.pauseReadiness(boundary) == .pending)
        let fresh = try #require(await native.replacements.first)
        await native.releaseReplacement()
        try #require(await streamEventually { await native.epochs[.microphone]?.id == fresh.id })
        #expect(await core.streamState(source: .system) != nil)
        #expect(pool.pauseReadiness(boundary) == .pending)
        micOut.yield(late)
        try #require(await streamEventually { await core.pausedSources == [.microphone,.system] })
        #expect(await native.barriers.contains { $0.kind == .pause && $0.scope.epochID == fresh.id && $0.sampleEnd == 0 })
        session.beginClosing(); micOut.finish(); systemOut.finish(); try await session.hardwareDidClose()
        let display = await store.projection()
        #expect(display.isClosed && display.segments.first { $0.source == .system }?.range.samples == .init(start: 0,end: 1600))
        #expect(await native.replacements.count == 1)
    }

    @MainActor @Test func immediateResumeStillSettlesTheFrozenOldPrefixBeforeReplacingIt() async throws {
        let f = StreamFixture(), input = f.input(), pool = LiveCaptureIngress(input: input)
        let native = StreamNativeFixture(input), store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core,retryInterval: .milliseconds(2))
        let derivative = session.derivativeSession()
        let (stream,output) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: stream,system: nil,language: "auto")))
        try #require(await streamEventually { await core.readySources.count == 1 })
        await native.configure(barrier: true)
        derivative.pause(); derivative.resume()
        try #require(await streamEventually { await native.barrierWaiter != nil })
        #expect(await native.replacements.isEmpty && pool.isAdmissionPaused(.microphone))
        await native.releaseBarrier()
        try #require(await streamEventually { !pool.isAdmissionPaused(.microphone) })
        #expect(await native.barriers.map(\.kind) == [.pause])
        #expect(await native.replacements.count == 1)
        session.beginClosing(); output.finish(); try await session.hardwareDidClose()
    }

    @MainActor @Test func idleDeviceHookMakesSourceLossVisibleSynchronouslyBeforeAnyConsumerWake() async throws {
        let f = StreamFixture(), input = f.input(both: true), pool = LiveCaptureIngress(input: input)
        let native = StreamNativeFixture(input), store = LiveTranscriptStore(identity: f.identity)
        await native.configure(replacement: true)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core,retryInterval: .milliseconds(2))
        let derivative = session.derivativeSession()
        let (mic,micOut) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let (system,systemOut) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: mic,system: system,language: "auto")))
        try #require(await streamEventually { await core.readySources.count == 2 })
        derivative.inputDeviceChanged()
        let micScope = LiveLaneScope(identity: f.identity,source: .microphone,epochID: input.epochs.first { $0.source == .microphone }!.id)
        let systemScope = LiveLaneScope(identity: f.identity,source: .system,epochID: input.epochs.first { $0.source == .system }!.id)
        // No actual converter exists to generate a later loss. The hook itself
        // must make a competing ordered event observe the device discontinuity.
        #expect(pool.continuityLoss(scope: micScope) == .deviceInterruption)
        #expect(pool.continuityLoss(scope: systemScope) == nil)
        session.beginClosing(); micOut.finish(); systemOut.finish(); try await session.hardwareDidClose()
        await native.releaseReplacement()
    }

    @Test(arguments: ["pause","finish","utterance"]) func zeroConverterTailCannotFlushProvisionalTextAcrossFrozenRawLoss(kind: String) async throws {
        let f = StreamFixture(), input = f.input(), pool = LiveCaptureIngress(input: input), native = StreamNativeFixture(input)
        let store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        try await core.start()
        try #require(await streamEventually { await core.readySources.count == 1 })
        let epoch = try #require(input.epochs.first)
        let scope = LiveLaneScope(identity: f.identity,source: .microphone,epochID: epoch.id)
        let normalizer = try LiveASRNormalizer(scope: scope,ingress: pool)
        let batch = try #require(try normalizer.convert(f.buffer(pool,frames: 1600,rate: 16000)))
        #expect(await core.offer(scope: scope,samples: batch.samples,reservation: batch.reservation) == .scheduled)
        try #require(await streamEventually { await native.packets.count == 1 })
        let lost = try f.buffer(pool,frames: 1600,rate: 16000,start: 1600)
        let boundary = try #require(pool.pauseAdmission(source: .microphone))
        lost.ingress?.discard(reason: .overload)
        let tail = try normalizer.finish()
        #expect(tail == nil && pool.canSealPause(boundary,scope: scope))
        if kind == "pause" { #expect(!(await core.requestPauseBoundary(scope: scope,boundary: boundary))) }
        else if kind == "utterance" { #expect(!(await core.requestUtteranceBoundary(scope: scope))) }
        else { await core.beginClosing(); await core.hardwareDidClose(); try await core.waitUntilClosed() }
        #expect(await streamEventually { await native.requests.contains { if case .cut(_,_,_,.overload) = $0 { true } else { false } } })
        await core.publishIngressLosses(source: .microphone); await core.synchronizeStore()
        let display = await store.projection()
        #expect(display.segments.isEmpty)
        #expect(display.coverage.contains { $0.kind == .gap(.overload) && $0.range.samples == .init(start: 0,end: 1600) })
        if kind != "finish" { await core.retire(); try await core.waitUntilClosed() }
    }

    @Test(arguments: ["pause","finish"]) func rawLossWhileAFlushCommandIsHeldRejectsItsLateCommit(kind: String) async throws {
        let f = StreamFixture(), input = f.input(), pool = LiveCaptureIngress(input: input), native = StreamNativeFixture(input)
        await native.configure(barrier: true)
        let store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        try await core.start()
        try #require(await streamEventually { await core.readySources.count == 1 })
        let epoch = try #require(input.epochs.first)
        let scope = LiveLaneScope(identity: f.identity,source: .microphone,epochID: epoch.id)
        let normalizer = try LiveASRNormalizer(scope: scope,ingress: pool)
        let batch = try #require(try normalizer.convert(f.buffer(pool,frames: 1600,rate: 16000)))
        #expect(await core.offer(scope: scope,samples: batch.samples,reservation: batch.reservation) == .scheduled)
        let boundary = try #require(pool.pauseAdmission(source: .microphone))
        let tail = try normalizer.finish(); #expect(tail == nil)
        if kind == "pause" { #expect(await core.requestPauseBoundary(scope: scope,boundary: boundary)) }
        else { await core.beginClosing(); await core.hardwareDidClose() }
        try #require(await streamEventually { await native.barrierWaiter != nil })
        pool.recordLoss(source: .microphone,metadata: .init(sourceEpoch: f.rawEpoch,role: .mic,timestamp: .unavailable,
            emittedFrames: .init(startFrame: 1600,frameCount: 1600,sampleRate: 16000),writeOutcome: .failed,converter: nil),reason: .overload)
        await native.releaseBarrier()
        try #require(await streamEventually {
            if kind == "finish" { return await store.projection().isClosed }
            if await core.pausedSources.contains(.microphone) { return true }
            return await native.requests.contains { if case .cut = $0 { true } else { false } }
        })
        await core.publishIngressLosses(source: .microphone); await core.synchronizeStore()
        let display = await store.projection()
        #expect(display.segments.isEmpty)
        #expect(display.coverage.contains { $0.kind == .gap(.overload) && $0.range.samples == .init(start: 0,end: 1600) })
        await core.retire(); try await core.waitUntilClosed()
    }

    @Test(arguments: ["converter","normalized-tail"]) func converterAndUnclaimedEofLossCutOnlyTheAdmittedProvisionalPrefix(kind: String) async throws {
        let f = StreamFixture(), input = f.input(), pool = LiveCaptureIngress(input: input), native = StreamNativeFixture(input)
        let store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        try await core.start()
        try #require(await streamEventually { await core.readySources.count == 1 })
        let epoch = try #require(input.epochs.first)
        let scope = LiveLaneScope(identity: f.identity,source: .microphone,epochID: epoch.id)
        let normalizer = try LiveASRNormalizer(scope: scope,ingress: pool)
        let batch = try #require(try normalizer.convert(f.buffer(pool)))
        #expect(await core.offer(scope: scope,samples: batch.samples,reservation: batch.reservation) == .scheduled)
        var held: LiveASRNormalizer.Batch?
        let reason: LiveGapReason = kind == "converter" ? .deviceInterruption : .overload
        if kind == "converter" { normalizer.cancel(reason: reason) }
        else { held = try normalizer.finish(); try #require(held != nil); held?.reservation.recordLoss(reason: reason) }
        #expect(pool.continuityLoss(scope: scope) == reason)
        await core.beginClosing(); await core.hardwareDidClose(); try await core.waitUntilClosed()
        let display = await store.projection()
        #expect(display.segments.isEmpty)
        #expect(display.coverage.contains { $0.kind == .gap(reason) && $0.range.samples == .init(start: 0,end: Int64(batch.samples.count)) })
        #expect(display.captureLosses.contains { $0.reason == reason && $0.frames == nil })
        if kind == "normalized-tail" {
            #expect(pool.statistics(.microphone).pendingSamples == 4096 + (held?.samples.count ?? 0))
            held = nil; #expect(pool.statistics(.microphone).pendingSamples == 4096)
        }
    }
    @Test func pauseCannotSealUntilTheRealConverterTailAndOriginalReceiptAreAdmitted() async throws {
        let f = StreamFixture(), input = f.input(), pool = LiveCaptureIngress(input: input), native = StreamNativeFixture(input)
        let store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        try await core.start()
        try #require(await streamEventually { await core.readySources.count == 1 })
        let epoch = try #require(input.epochs.first)
        let scope = LiveLaneScope(identity: f.identity,source: .microphone,epochID: epoch.id)
        let normalizer = try LiveASRNormalizer(scope: scope,ingress: pool)
        let batch = try #require(try normalizer.convert(f.buffer(pool)))
        let boundary = try #require(pool.pauseAdmission(source: .microphone))
        #expect(pool.pauseReadiness(boundary) == .drained)
        #expect(!(await core.requestPauseBoundary(scope: scope,boundary: boundary)))
        #expect(await core.offer(scope: scope,samples: batch.samples,reservation: batch.reservation) == .scheduled)
        #expect(!(await core.requestPauseBoundary(scope: scope,boundary: boundary)))
        if let tail = try normalizer.finish() {
            #expect(!(await core.requestPauseBoundary(scope: scope,boundary: boundary)))
            #expect(await core.offer(scope: scope,samples: tail.samples,reservation: tail.reservation) == .scheduled)
        }
        #expect(pool.canSealPause(boundary,scope: scope))
        #expect(!(await core.requestPauseBoundary(scope: scope)))
        #expect(await core.requestPauseBoundary(scope: scope,boundary: boundary))
        try #require(await streamEventually { await native.barriers.contains { $0.kind == .pause } })
        let barrier = await native.barriers.first
        #expect(barrier?.sampleEnd == 1600 && barrier?.nextPacketSequence == 2)
        #expect(await native.packets.reduce(0) { $0 + $1.sampleCount } == 1600)
        await core.retire(); try await core.waitUntilClosed()
    }
    @Test func realStreamSplitsAtTheFifteenSecondBoundaryWithoutResettingItsConverterOrEpoch() async throws {
        let f = StreamFixture(), input = f.input(), pool = LiveCaptureIngress(input: input), native = StreamNativeFixture(input)
        let store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core)
        let (stream,output) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: stream,system: nil,language: "auto")))
        #expect(await streamEventually { await core.readySources.count == 1 })
        for index in 0..<151 {
            let packetsBefore = await native.packets.count
            output.yield(try f.buffer(pool,start: index*4800))
            try #require(await streamEventually { await native.packets.count > packetsBefore })
        }
        #expect(await streamEventually { await native.barriers.contains { $0.kind == .utterance } })
        session.beginClosing(); output.finish(); try await session.hardwareDidClose()
        let barriers = await native.barriers, packets = await native.packets, display = await store.projection()
        #expect(barriers.map(\.kind) == [.utterance,.finish])
        #expect(barriers.map(\.sampleEnd) == [240000,241600])
        #expect(packets.contains { $0.startSample + Int64($0.sampleCount) == 240000 })
        #expect(packets.reduce(0) { $0 + $1.sampleCount } == 241600)
        #expect(packets.allSatisfy { $0.scope.epochID == input.epochs.first?.id && $0.sampleCount <= 3200 })
        #expect(display.segments.map { $0.range.samples } == [.init(start: 0,end: 240000),.init(start: 240000,end: 241600)])
        #expect(display.captureLosses.isEmpty && display.isClosed)
        #expect(pool.statistics(.microphone).pendingSamples == 4096)
        #expect(await native.replacements.isEmpty)
    }

    @Test func rawLossBetweenConversionAndOfferCannotAdvanceTheOldQualifiedEpoch() async throws {
        let f = StreamFixture(), input = f.input(origin: 1_000_000_000), pool = LiveCaptureIngress(input: input)
        let native = StreamNativeFixture(input), store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        try await core.start()
        #expect(await streamEventually { await core.readySources.count == 1 })
        await core.synchronizeStore()
        let initialCoverage = await store.projection().coverage
        let epoch = try #require(input.epochs.first), scope = LiveLaneScope(identity: input.identity,source: .microphone,epochID: epoch.id)
        let normalizer = try LiveASRNormalizer(scope: scope,ingress: pool)
        let converted = try normalizer.convert(f.buffer(pool,start: 4800))
        let batch = try #require(converted)
        pool.recordLoss(source: .microphone,metadata: .init(sourceEpoch: f.rawEpoch,role: .mic,timestamp: .unavailable,
            emittedFrames: .init(startFrame: 0,frameCount: 4800,sampleRate: 48000),writeOutcome: .failed,converter: nil),reason: .unavailable)
        #expect(await core.offer(scope: scope,samples: batch.samples,reservation: batch.reservation) == .dropped)
        normalizer.cancel(reason: .unavailable)
        await core.publishIngressLosses(source: .microphone)
        await core.synchronizeStore()
        let display = await store.projection()
        #expect(display.lanes.first?.progress.capturedSampleEnd == 0)
        #expect(display.coverage == initialCoverage && display.segments.isEmpty)
        #expect(await native.packets.isEmpty)
        #expect(display.captureLosses.contains { $0.frames == nil })
        await core.retire(); try await core.waitUntilClosed()
    }

    @MainActor @Test(arguments: [false,true]) func realDerivativeAdapterPreservesHardwareFirstClosureAndIndependentDeadline(leaveStreamOpen: Bool) async throws {
        let f = StreamFixture(), input = f.input(), pool = LiveCaptureIngress(input: input), native = StreamNativeFixture(input)
        await native.configure(begin: leaveStreamOpen)
        let store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core)
        let derivative = session.derivativeSession()
        let (mic,micOut) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let (system,systemOut) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        var calls: [String] = []
        let capture = CaptureCoordinator(hardware: .init(start: { _,_ in .init(mic: mic,system: system) },stop: {
            calls.append("hardware-close")
            if !leaveStreamOpen {
                if let tail = try? f.buffer(pool,frames: 48000,closingTail: true) { micOut.yield(tail) }
                else { Issue.record("Closing raw tail was rejected") }
                micOut.finish(); systemOut.finish()
            }
        },snapshot: { .init(duration: 1,microphoneEnabled: true) },pause: {},resume: {},switchInputDevice: { _ in }),
        persistence: .init(create: { id,date in
            let root = URL(fileURLWithPath: "/tmp/registered-stream-adapter/\(id)")
            return .init(id: id,startedAt: date,files: .init(directoryURL: root,manifestURL: root.appendingPathComponent("session.json"),captureBaseURL: root.appendingPathComponent("capture")))
        },began: { _,_ in },failedStart: { _,_,_ in },stopped: { capture,state,_ in
            await MainActor.run { calls.append("audio-checkpoint") }
            return .init(session: capture,state: state,fileSize: 1,duration: 1)
        },termination: { _ in },pauseResume: { _,_,_ in }),derivative: .init(make: { _,_ in derivative }),
        derivativeDrainDeadline: leaveStreamOpen ? .milliseconds(60) : .seconds(3),onEvent: { _ in })
        let request = CaptureCoordinator.Request(id: f.identity.recordingID,startedAt: Date(),captureSessionID: f.identity.captureSessionID,
            liveIngress: pool,liveTranscription: true,language: "auto")
        try await capture.start(request)
        #expect(await streamEventually { await native.begins == 1 })
        if !leaveStreamOpen { #expect(await streamEventually { await core.readySources.count == 1 }) }
        await capture.stop()
        #expect(calls == ["hardware-close","audio-checkpoint"] && !capture.isBusy)
        #expect(await streamEventually { await store.projection().isClosed })
        let frozen = await store.snapshot()
        if leaveStreamOpen {
            #expect(await native.beginWaiter != nil)
            #expect(await native.barriers.isEmpty)
            micOut.finish(); systemOut.finish(); await native.release()
            #expect(await streamEventually { await native.shutdowns > 0 })
            #expect(await store.snapshot() == frozen)
        } else {
            #expect(await store.projection().segments.first?.range.samples == .init(start: 0,end: 16000))
            #expect(await native.barriers.last?.sampleEnd == 16000)
        }
    }

    @Test(arguments: [false,true]) func abandonedReplacementPreservesHealthyClosingTailAndNativeCredit(stopWins: Bool) async throws {
        let f = StreamFixture(), input = f.input(both: true), pool = LiveCaptureIngress(input: input), native = StreamNativeFixture(input)
        await native.configure(replacement: true,systemFinish: true,shutdown: true,consumeMicrophone: false)
        let store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core,
            replacementDeadline: stopWins ? .seconds(30) : .milliseconds(80),retryInterval: .milliseconds(2))
        let (mic,micOut) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let (system,systemOut) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: mic,system: system,language: "auto")))
        #expect(await streamEventually { await core.readySources.count == 2 })
        micOut.yield(try f.buffer(pool)); systemOut.yield(try f.buffer(pool,source: .system))
        #expect(await streamEventually { await native.packets.count == 2 })
        micOut.yield(try f.buffer(pool,start: 9600))
        #expect(await streamEventually { await native.replacements.count == 1 })
        let healthyTail = try f.buffer(pool,source: .system,start: 4800)
        if stopWins { session.beginClosing() }
        #expect(await streamEventually { await core.streamState(source: .microphone)?.gapReason == .unavailable })
        let replacement = try #require(await native.replacements.first)
        await native.releaseReplacement()
        #expect(await streamEventually { await native.epochs[.microphone]?.id == replacement.id })
        systemOut.yield(healthyTail)
        #expect(await streamEventually { await native.packets.filter { $0.scope.source == .system }.count == 2 })
        session.beginClosing(); micOut.finish(); systemOut.finish()
        let drain = Task { try await session.hardwareDidClose() }
        #expect(await streamEventually { await native.systemFinishWaiter != nil })
        #expect(await native.barriers.allSatisfy { $0.scope.source == .system })
        #expect(!(await store.projection().isClosed))
        #expect(pool.statistics(.microphone).nativeSamples > 0)
        await native.releaseSystemFinish(); try await drain.value
        let display = await store.projection()
        #expect(display.segments.contains { $0.source == .system && $0.range.samples == .init(start: 0,end: 3200) })
        #expect(display.lanes.first { $0.epoch.source == .microphone }?.epoch.id == input.epochs.first?.id)
        #expect(await streamEventually { await native.shutdownWaiter != nil })
        #expect(pool.statistics(.microphone).nativeSamples > 0)
        await native.releaseShutdown()
        #expect(await streamEventually { pool.statistics(.microphone).nativeSamples == 0 })
    }

    @Test(arguments: [false,true]) func lossBeforeFirstConsumedBufferInvalidatesOnlyItsQualifiedOrigin(producerFailure: Bool) async throws {
        let f = StreamFixture(), input = f.input(both: true,origin: 1_000_000_000), pool = LiveCaptureIngress(input: input)
        let native = StreamNativeFixture(input), store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core)
        let (mic,micOut) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let (system,systemOut) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: mic,system: system,language: "auto")))
        #expect(await streamEventually { await core.readySources.count == 2 })
        if producerFailure {
            let metadata = LiveAudioMetadata(sourceEpoch: f.rawEpoch,role: .mic,timestamp: .unavailable,
                emittedFrames: .init(startFrame: 0,frameCount: 4800,sampleRate: 48000),writeOutcome: .failed,converter: nil)
            pool.recordLoss(source: .microphone,metadata: metadata,reason: .unavailable)
        } else {
            // The same RAII disposal happens when the bounded stream evicts raw
            // audio before its registered consumer observes the buffer.
            var evicted: LiveAudioBuffer? = try f.buffer(pool)
            withExtendedLifetime(evicted) { #expect(pool.statistics(.microphone).rawBytes > 0) }
            evicted = nil
        }
        await core.publishIngressLosses(source: .microphone)
        micOut.yield(try f.buffer(pool,start: 4800)); systemOut.yield(try f.buffer(pool,source: .system))
        #expect(await streamEventually { await native.replacements.count == 1 })
        #expect(await streamEventually { await core.readySources.count == 2 })
        micOut.yield(try f.buffer(pool,start: 9600))
        #expect(await streamEventually { await native.packets.count >= 2 })
        session.beginClosing(); micOut.finish(); systemOut.finish(); try await session.hardwareDidClose()
        let replacement = try #require(await native.replacements.first), display = await store.projection()
        #expect(replacement.source == .microphone && replacement.meetingOriginNanoseconds == nil)
        #expect(await native.packets.filter { $0.scope.source == .microphone }.allSatisfy { $0.scope.epochID == replacement.id })
        #expect(display.segments.filter { $0.source == .microphone }.allSatisfy { $0.range.meeting == nil })
        #expect(display.segments.first { $0.source == .system }?.range.meeting != nil)
        #expect(display.captureLosses.contains { $0.source == .microphone && $0.frames?.startFrame == 0 })
    }

    @Test func registeredEofDrainsRealConverterBeforeBoundedPacketsAndFinalBarrier() async throws {
        let f = StreamFixture(), input = f.input(), pool = LiveCaptureIngress(input: input), native = StreamNativeFixture(input)
        let store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core)
        let (stream,output) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: stream,system: nil,language: "auto")))
        #expect(!session.register(.init(mic: stream,system: nil,language: "auto")))
        #expect(await streamEventually { await core.readySources.contains(.microphone) })
        output.yield(try f.buffer(pool,frames: 48000))
        #expect(await streamEventually { await native.packets.count > 0 })
        session.beginClosing()
        let drain = Task { try await session.hardwareDidClose() }
        #expect(await native.barriers.isEmpty)
        output.finish(); try await drain.value
        let packets = await native.packets, barriers = await native.barriers
        #expect(packets.reduce(0) { $0 + $1.sampleCount } == 16000)
        #expect(packets.allSatisfy { $0.sampleCount > 0 && $0.sampleCount <= 3200 })
        for packet in packets { #expect(try packet.decodedSamples().allSatisfy { $0.isFinite }) }
        #expect(barriers.last?.sampleEnd == 16000 && barriers.last?.nextPacketSequence == UInt64(packets.count))
        #expect(await store.projection().isClosed)
        #expect(await store.projection().segments.first?.range.samples == .init(start: 0,end: 16000))
        #expect(pool.statistics(.microphone).rawBytes == 0 && pool.statistics(.microphone).converterSamples == 0)
        #expect(await store.snapshot().captureLosses == nil)
    }

    @Test func pendingNativePreparationDropsRawInputAndExpiryDoesNotJoinItsLateCompletion() async throws {
        let f = StreamFixture(), input = f.input(), pool = LiveCaptureIngress(input: input), native = StreamNativeFixture(input)
        await native.configure(begin: true)
        let store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core)
        let (stream,output) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: stream,system: nil,language: "auto")))
        #expect(await streamEventually { await native.begins == 1 })
        for index in 0..<4 { output.yield(try f.buffer(pool,start: index*4800)) }
        #expect(await streamEventually { await store.projection().captureLosses.reduce(0) { $0 + $1.bufferCount } == 4 })
        #expect(pool.statistics(.microphone).rawBytes == 0)
        session.beginClosing(); session.expire()
        #expect(await streamEventually { await store.projection().isClosed })
        let frozen = await store.snapshot()
        #expect(frozen.lanes.first?.progress.capturedSampleEnd == 0)
        #expect((frozen.captureLosses ?? []).compactMap(\.frames).reduce(0) { $0 + $1.frameCount } == 19200)
        #expect((frozen.captureLosses ?? []).compactMap { $0.frames?.startFrame } == [0,4800,9600,14400])
        await native.release(); output.finish()
        #expect(await streamEventually { await native.shutdowns >= 1 })
        #expect(await store.snapshot() == frozen)
        #expect(!session.register(.init(mic: stream,system: nil,language: "auto")))
    }

    @Test func aForeignPoolOrLanguageCannotRegisterOrRetireAnotherCapture() async throws {
        let f = StreamFixture(), input = f.input(), pool = LiveCaptureIngress(input: input), native = StreamNativeFixture(input)
        let store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let other = StreamFixture(), foreign = LiveCaptureIngress(input: other.input())
        #expect(throws: (any Error).self) { try LiveCaptureStreamSession(input: input,ingress: foreign,coordinator: core) }
        let ticket = try other.buffer(foreign)
        #expect(ticket.ingress != nil)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core)
        let (stream,output) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(!session.register(.init(mic: stream,system: nil,language: "nl")))
        #expect(await native.begins == 0)
        output.finish(); session.expire()
    }

    @Test func aRawCounterGapReplacesOnlyThatSourceAndKeepsTheOtherConsumerAlive() async throws {
        let f = StreamFixture(), input = f.input(both: true), pool = LiveCaptureIngress(input: input), native = StreamNativeFixture(input)
        let store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core)
        let (mic,micOut) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let (system,systemOut) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: mic,system: system,language: "auto")))
        #expect(await streamEventually { await core.readySources.count == 2 })
        micOut.yield(try f.buffer(pool))
        systemOut.yield(try f.buffer(pool,source: .system))
        #expect(await streamEventually { await native.packets.count >= 2 })
        micOut.yield(try f.buffer(pool,start: 9600))
        #expect(await streamEventually {
            let count = await native.replacements.count, ready = await core.readySources.count
            return count == 1 && ready == 2
        })
        micOut.yield(try f.buffer(pool,start: 14400))
        systemOut.yield(try f.buffer(pool,source: .system,start: 4800))
        #expect(await streamEventually { await native.packets.count >= 4 })
        session.beginClosing(); micOut.finish(); systemOut.finish()
        try await session.hardwareDidClose()
        let replacements = await native.replacements, display = await store.projection()
        #expect(replacements.count == 1 && replacements.first?.source == .microphone)
        #expect(display.segments.contains { $0.source == .system && $0.range.samples == .init(start: 0,end: 3200) })
        #expect(display.segments.contains { $0.id.epochID == replacements.first?.id })
        #expect(display.captureLosses.contains { $0.source == .microphone && $0.frames?.startFrame == 9600 })
        #expect(display.captureLosses.contains { $0.source == .microphone && $0.frames == nil })
        #expect(display.captureLosses.allSatisfy { $0.source == .microphone })
    }

    @Test func blockedReplacementCannotStallRawConsumptionOrAdoptAfterExpiry() async throws {
        let f = StreamFixture(), input = f.input(), pool = LiveCaptureIngress(input: input), native = StreamNativeFixture(input)
        await native.configure(replacement: true)
        let store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core)
        let (stream,output) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: stream,system: nil,language: "auto")))
        #expect(await streamEventually { await core.readySources.count == 1 })
        output.yield(try f.buffer(pool))
        #expect(await streamEventually { await native.packets.count > 0 })
        output.yield(try f.buffer(pool,start: 9600))
        #expect(await streamEventually { await native.replacements.count == 1 })
        for index in 3..<7 { output.yield(try f.buffer(pool,start: index*4800)) }
        #expect(await streamEventually { pool.statistics(.microphone).rawBytes == 0 })
        #expect(await native.replacements.count == 1)
        session.expire(); output.finish()
        #expect(await streamEventually { await store.projection().isClosed })
        let frozen = await store.snapshot()
        #expect((frozen.captureLosses ?? []).filter { ($0.frames?.startFrame ?? -1) >= 14400 }.reduce(0) { $0 + $1.bufferCount } == 4)
        await native.release()
        #expect(await streamEventually { await native.shutdowns > 0 })
        #expect(await store.snapshot() == frozen)
        #expect(frozen.lanes.first?.epoch.id == input.epochs.first?.id)
    }

    @Test func droppedOldInputCannotCutAFreshReplacementEpochAgain() async throws {
        let f = StreamFixture(), input = f.input(), pool = LiveCaptureIngress(input: input), native = StreamNativeFixture(input)
        await native.configure(replacement: true)
        let store = LiveTranscriptStore(identity: f.identity)
        let core = LiveCaptureSessionCoordinator(input: input,store: store,transport: await native.transport(),ingress: pool)
        let session = try LiveCaptureStreamSession(input: input,ingress: pool,coordinator: core)
        let (stream,output) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        #expect(session.register(.init(mic: stream,system: nil,language: "auto")))
        #expect(await streamEventually { await core.readySources.count == 1 })
        output.yield(try f.buffer(pool))
        #expect(await streamEventually { await native.packets.count > 0 })
        output.yield(try f.buffer(pool,start: 9600))
        #expect(await streamEventually { await native.replacements.count == 1 })
        for index in 3..<7 { output.yield(try f.buffer(pool,start: index*4800)) }
        #expect(await streamEventually { pool.statistics(.microphone).rawBytes == 0 })
        await native.release()
        #expect(await streamEventually { await core.readySources.count == 1 })
        output.yield(try f.buffer(pool,start: 33600))
        #expect(await streamEventually { await native.packets.count >= 2 })
        #expect(await native.replacements.count == 1)
        session.beginClosing(); output.finish(); try await session.hardwareDidClose()
        #expect(await store.projection().segments.count == 1)
    }
}
