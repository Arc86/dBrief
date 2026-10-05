import Darwin
import Foundation
import Testing
import dBriefWire
@testable import dBriefMLHost

private actor HPgate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    func wait() async { entered = true; if !open { await withCheckedContinuation { waiting.append($0) } } }
    func release() { open = true; let held = waiting; waiting = []; for w in held { w.resume() } }
}
private final class HPaudit: @unchecked Sendable {
    private let lock = NSLock()
    private var normal: [LiveSessionEvent] = [], optional: [LiveDiarizationEvent] = []
    private var hits: [String: Int] = [:], acknowledged: Set<UInt64> = []
    private var rejectOutput = false
    private var loadedConfiguration: LiveDiarizationConfiguration?
    func reject() { lock.withLock { rejectOutput = true } }
    func loaded(_ configuration: LiveDiarizationConfiguration) { lock.withLock { loadedConfiguration = configuration } }
    var configuration: LiveDiarizationConfiguration? { lock.withLock { loadedConfiguration } }
    func emit(_ e: LiveSessionEvent) { lock.withLock { normal.append(e) } }
    func emitOptional(_ e: LiveDiarizationEvent) -> Bool { lock.withLock { optional.append(e); return !rejectOutput } }
    func hit(_ k: String) { lock.withLock { hits[k, default: 0] += 1 } }
    func count(_ k: String) -> Int { lock.withLock { hits[k, default: 0] } }
    var lanes: [LiveLaneEvent] { lock.withLock { normal.compactMap { if case .lane(let l) = $0 { l } else { nil } } } }
    var events: [LiveDiarizationEvent] { lock.withLock { optional } }
    var ready: Bool { lanes.contains { if case .ready = $0.payload { true } else { false } } }
    var terminal: Bool { lock.withLock { normal.contains { if case .finished = $0 { true } else { false } } } }
    var commits: [CommittedLiveSegment] { lanes.compactMap { if case .committed(let s) = $0.payload { s } else { nil } } }
    var retired: Bool { events.contains { if case .retired = $0.payload { true } else { false } } }
    var context: UUID? { events.compactMap { if case .ready(_, let c) = $0.payload { c } else { nil } }.first }
    var rows: [LiveDiarizationRow] { events.flatMap { e -> [LiveDiarizationRow] in if case .posterior(_, let rows) = e.payload { return rows }; return [] } }
    func newPackets() -> [LiveDiarizationEvent] { lock.withLock {
        let result = optional.filter { if case .posterior = $0.payload { !acknowledged.contains($0.sequence) } else { false } }
        for e in result { acknowledged.insert(e.sequence) }; return result
    } }
}
private actor HPdecoder: NemotronStreamingDecoder {
    let audit: HPaudit
    private var total: Int64 = 0
    init(_ audit: HPaudit) { self.audit = audit }
    func process(samples: [Float]) async throws -> NemotronDecoderProgress {
        total += Int64(samples.count); audit.hit("asr-append")
        return .init(consumedSamples: total, heldSamples: 0)
    }
    func finish() async throws -> NemotronDecoderOutput { audit.hit("asr-finish"); return .init(text: "unchanged ASR", timings: []) }
}
private struct HPfactory: NemotronDecoderMaking {
    let audit: HPaudit
    func makeDecoder(configuration: NemotronDecoderConfiguration, partial: @escaping @Sendable (String) -> Void) async throws -> any NemotronStreamingDecoder {
        audit.hit("asr-made"); return HPdecoder(audit)
    }
}
private actor HPdriver: LiveDiarizationDriving {
    let audit: HPaudit, appendGate: HPgate?, shutdownGate: HPgate?, finishGate: HPgate?
    private var total = 0, emitted = 0
    init(_ audit: HPaudit, append: HPgate? = nil, shutdown: HPgate? = nil, finish: HPgate? = nil) {
        self.audit = audit; appendGate = append; shutdownGate = shutdown; finishGate = finish
    }
    deinit { audit.hit("driver-dead") }
    func append(_ samples: [Float]) async throws -> [LiveDiarizationChunk] {
        audit.hit("diar-append"); total += samples.count; await appendGate?.wait()
        let n = total / 160 - emitted; emitted += n
        // Independent probabilities intentionally sum above1.
        return n == 0 ? [] : [.init(frameCount: n, probabilities: Array(repeating: [Float](repeating: 0.7, count: 8), count: n).flatMap { $0 })]
    }
    func finish() async throws -> [LiveDiarizationChunk] {
        audit.hit("diar-finish"); await finishGate?.wait()
        let n = (total + 159) / 160 + 1 - emitted; emitted += n
        return [.init(frameCount: n, probabilities: [Float](repeating: 0.8, count: n * 8))]
    }
    func shutdown() async { audit.hit("shutdown"); await shutdownGate?.wait() }
}
private actor HPvad: LiveVADModelHandle {
    nonisolated let assets: LiveVADModelAssets
    init(_ assets: LiveVADModelAssets) { self.assets = assets }
    func validate(_ c: LiveVADModelContract) throws { try c.validate(VADLoadFixture.description) }
    func predict(_ input: LiveVADNativeInput) async throws -> LiveVADNativeOutput {
        try .init(probability: 0, hiddenState: [Float](repeating: 0, count: 128), cellState: [Float](repeating: 0, count: 128))
    }
}
private struct HPfixture {
    let scope = LiveLaneScope(identity: .init(recordingID: UUID(), captureSessionID: UUID()), source: .system, epochID: UUID())
    let owner = UUID()
    var configuration: LiveDiarizationConfiguration { .init(identity: .init(modelFingerprint: String(repeating: "e", count: 64), preset: .low), modelDirectory: "/private/fixture-diar") }
    func epoch(_ id: UUID? = nil, origin: Int64? = 1_000_000_000) -> LiveEpoch {
        .init(id: id ?? scope.epochID, source: .system, engineRevision: "fixture", language: "en", meetingOriginNanoseconds: origin)
    }
    func start(_ audit: HPaudit, load: HPgate? = nil, append: HPgate? = nil, shutdown: HPgate? = nil, finish: HPgate? = nil,
               vad: VADLoadFixture? = nil, frozen: Bool = false, disposal: @escaping @Sendable (LiveLaneScope) -> Void = { _ in }) async throws -> LiveASROrchestrator {
        let vadLoader: LiveASROrchestrator.VADLoader?
        if let fixture = vad {
            vadLoader = { input in
                let assets = try await fixture.assets()
                return try await LiveVADModelFactory.load(configuration: input.vad!, sources: [.system], assets: assets) { assets, _ in HPvad(assets) }
            }
        } else { vadLoader = nil }
        let helper = LiveASROrchestrator(loader: { _ in HPfactory(audit: audit) }, vadLoader: vadLoader, diarizationLoader: { configuration in
            audit.loaded(configuration); audit.hit("load"); await load?.wait(); return HPdriver(audit, append: append, shutdown: shutdown, finish: finish)
        }, diarizationEmit: audit.emitOptional, emit: audit.emit, testingPacketDisposed: disposal)
        #expect(await helper.handle(.begin(.init(identity: scope.identity, configuration: .init(language: .en, chunkMs: 560, modelDirectory: "/fixture-asr"), epochs: [epoch()], vad: vad?.configuration, diarization: frozen ? .init(ownerID: owner, configuration: configuration) : nil)), requestID: UUID()) == .accepted)
        try #require(await HPuntil { audit.ready })
        return helper
    }
    var prepare: LiveSessionRequest { .prepareDiarization(scope: scope, ownerID: owner, configuration: configuration) }
    func packet(_ seq: UInt64, _ start: Int64, _ count: Int = 160, scope: LiveLaneScope? = nil) throws -> LiveSessionRequest {
        .packet(try .init(scope: scope ?? self.scope, sequence: seq, startSample: start, samples: [Float](repeating: 1, count: count)))
    }
    func barrier(_ seq: UInt64, _ end: Int64, _ kind: LiveFinishBarrier.Kind, scope: LiveLaneScope? = nil) -> LiveSessionRequest {
        .barrier(.init(scope: scope ?? self.scope, nextPacketSequence: seq, sampleEnd: end, kind: kind))
    }
    func drain(_ h: LiveASROrchestrator, _ a: HPaudit) async throws {
        try #require(await HPuntil {
            if let c = a.context { _ = await h.handle(.acknowledgeDiarization(identity: scope.identity, ownerID: owner, contextID: c), requestID: UUID()) }
            for e in a.newPackets() {
                guard case .posterior(let c, _) = e.payload else { continue }
                #expect(await h.handle(.acknowledgeDiarizationPosterior(identity: scope.identity, ownerID: owner, contextID: c, sequence: e.sequence), requestID: UUID()) == .accepted)
            }
            return await h.diarizationIsIdle
        })
    }
    func cleanup(_ h: LiveASROrchestrator) async { _ = await h.handle(.cancel(scope.identity), requestID: UUID()); await h.joinDiarizationRetirement() }
}
private func HPsyncWait(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult { semaphore.wait(timeout: .now() + 2) }
private func HPuntil(_ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<1000 { if await predicate() { return true }; try? await Task.sleep(for: .milliseconds(2)) }; return false
}

@Suite struct LiveDiarizationProducerTests {
    @Test(arguments: [false, true]) func heldPreparationDoesNotHoldASRAndLateOriginExcludesEarlierPCM(configured: Bool) async throws {
        let f = HPfixture(), a = HPaudit(), load = HPgate(), v = configured ? try VADLoadFixture() : nil
        defer { v?.cleanup() }
        let h = try await f.start(a, load: load, vad: v)
        #expect(await h.handle(f.prepare, requestID: UUID()) == .accepted)
        try #require(await HPuntil { await load.entered })
        #expect(try await h.handle(f.packet(0, 0, 3200), requestID: UUID()) == .accepted)
        #expect(await h.handle(f.barrier(1, 3200, .utterance), requestID: UUID()) == .accepted)
        try #require(await HPuntil { a.commits.count == 1 })
        #expect(a.commits[0].diarizerContextID == nil && a.count("diar-append") == 0)
        await load.release(); try #require(await HPuntil { await h.diarizationIsIdle })
        #expect(try await h.handle(f.packet(1, 3200, 3200), requestID: UUID()) == .accepted)
        try await f.drain(h, a)
        #expect(a.rows.first?.samples.start == 3200 && a.rows.last?.samples.end == 6400)
        #expect(a.rows.first?.streamSamples.start == 0 && a.rows.last?.streamSamples.end == 3200)
        #expect(a.rows.first?.meeting?.startNanoseconds == 1_200_000_000)
        #expect(a.events.contains { if case .ready(3200, _) = $0.payload { true } else { false } })
        #expect(await h.handle(f.barrier(2, 6400, .utterance), requestID: UUID()) == .accepted)
        try #require(await HPuntil { a.commits.count == 2 })
        #expect(a.commits[1].diarizerContextID == a.context && a.commits[1].text == "unchanged ASR")
        #expect(a.count("diar-finish") == 0 && a.count("load") == 1)
        await f.cleanup(h); #expect(a.count("shutdown") == 1)
    }
    @Test func heldAppendBusyRetiresLabelsWhileASRAndFinalBarrierContinue() async throws {
        let f = HPfixture(), a = HPaudit(), append = HPgate(), shutdown = HPgate(), h = try await f.start(a, append: append, shutdown: shutdown)
        #expect(await h.handle(f.prepare, requestID: UUID()) == .accepted)
        try #require(await HPuntil { await h.diarizationIsIdle })
        #expect(try await h.handle(f.packet(0, 0), requestID: UUID()) == .accepted)
        try #require(await HPuntil { await append.entered })
        #expect(try await h.handle(f.packet(1, 160), requestID: UUID()) == .accepted)
        #expect(await h.handle(f.barrier(2, 320, .finish), requestID: UUID()) == .accepted)
        try #require(await HPuntil { a.terminal })
        #expect(a.count("asr-append") == 2 && a.count("diar-append") == 1 && !a.retired)
        await append.release(); try #require(await HPuntil { await shutdown.entered })
        #expect(!a.retired && a.count("shutdown") == 1 && a.count("driver-dead") == 0)
        await shutdown.release(); await h.joinDiarizationRetirement()
        #expect(a.retired && a.rows.isEmpty && a.count("shutdown") == 1)
        await f.cleanup(h)
    }
    @Test func canceledHeldConstructionJoinsReturnedNativeShutdownBeforeReceipt() async throws {
        let f = HPfixture(), a = HPaudit(), load = HPgate(), shutdown = HPgate(), h = try await f.start(a, load: load, shutdown: shutdown)
        #expect(await h.handle(f.prepare, requestID: UUID()) == .accepted)
        try #require(await HPuntil { await load.entered })
        #expect(await h.handle(.retireDiarization(identity: f.scope.identity, ownerID: UUID()), requestID: UUID()) == .rejected(.staleScope))
        #expect(await h.handle(.retireDiarization(identity: f.scope.identity, ownerID: f.owner), requestID: UUID()) == .accepted)
        #expect(!a.retired && a.context == nil)
        await load.release(); try #require(await HPuntil { await shutdown.entered })
        #expect(!a.retired && a.count("driver-dead") == 0)
        await shutdown.release(); await h.joinDiarizationRetirement()
        #expect(a.retired && a.context == nil && a.rows.isEmpty)
        #expect(await h.handle(f.prepare, requestID: UUID()) == .rejected(.closed))
        await f.cleanup(h)
    }
    @Test func pauseTailPreservesContextAndDoesNotFillMissingMeetingClock() async throws {
        let f = HPfixture(), a = HPaudit(), h = try await f.start(a)
        #expect(await h.handle(f.prepare, requestID: UUID()) == .accepted)
        try #require(await HPuntil { await h.diarizationIsIdle })
        #expect(try await h.handle(f.packet(0, 0, 80), requestID: UUID()) == .accepted); try await f.drain(h, a)
        #expect(await h.handle(f.barrier(1, 80, .pause), requestID: UUID()) == .accepted)
        try #require(await HPuntil { await h.diarizationIsPaused })
        let next = f.epoch(UUID(), origin: nil), scope = LiveLaneScope(identity: f.scope.identity, source: .system, epochID: next.id)
        #expect(await h.handle(.replaceEpoch(identity: f.scope.identity, oldEpochID: f.scope.epochID, epoch: next), requestID: UUID()) == .accepted)
        try #require(await HPuntil { await h.diarizationIsIdle })
        try #require(await HPuntil { a.lanes.contains { e in guard e.scope == scope else { return false }; if case .ready = e.payload { return true }; return false } })
        #expect(try await h.handle(f.packet(0, 0, 80, scope: scope), requestID: UUID()) == .accepted); try await f.drain(h, a)
        #expect(a.rows.count == 2 && a.rows[0].samples == .init(start: 0, end: 80) && a.rows[1].samples == .init(start: 0, end: 80))
        #expect(a.events.filter { if case .ready = $0.payload { true } else { false } }.count == 1)
        #expect(a.rows[0].meeting == .init(startNanoseconds: 1_000_000_000, endNanoseconds: 1_005_000_000) && a.rows[1].meeting == nil)
        #expect(a.count("diar-finish") == 0 && a.count("load") == 1)
        await f.cleanup(h)
    }
    @Test func outputCreditAndContextAcknowledgementCannotBeGuessed() async throws {
        let f = HPfixture(), a = HPaudit(), h = try await f.start(a)
        #expect(await h.handle(f.prepare, requestID: UUID()) == .accepted)
        try #require(await HPuntil { await h.diarizationIsIdle })
        #expect(try await h.handle(f.packet(0, 0, 3200), requestID: UUID()) == .accepted)
        try #require(await HPuntil { a.context != nil && a.count("diar-append") == 1 })
        #expect(a.rows.isEmpty)
        #expect(await h.handle(.acknowledgeDiarization(identity: f.scope.identity, ownerID: f.owner, contextID: UUID()), requestID: UUID()) == .rejected(.staleScope))
        #expect(await h.handle(f.barrier(1, 3200, .utterance), requestID: UUID()) == .accepted)
        try #require(await HPuntil { a.commits.count == 1 }); #expect(a.commits[0].diarizerContextID == nil)
        let c = try #require(a.context)
        #expect(await h.handle(.acknowledgeDiarization(identity: f.scope.identity, ownerID: f.owner, contextID: c), requestID: UUID()) == .accepted)
        try #require(await HPuntil { a.rows.count == 2 })
        let first = try #require(a.events.last)
        #expect(await h.handle(.acknowledgeDiarizationPosterior(identity: f.scope.identity, ownerID: f.owner, contextID: c, sequence: first.sequence + 1), requestID: UUID()) == .rejected(.outOfOrder))
        #expect(a.rows.count == 2); try await f.drain(h, a); #expect(a.rows.count == 20)
        #expect(a.rows.allSatisfy { (try? $0.activityValues()) == [Float](repeating: 0.7, count: 8) })
        await f.cleanup(h)
    }
    @Test func cutAndWriterRejectionRetireOnlyOptionalSource() async throws {
        for writerFailure in [false, true] {
            let f = HPfixture(), a = HPaudit(), h = try await f.start(a)
            #expect(await h.handle(f.prepare, requestID: UUID()) == .accepted)
            try #require(await HPuntil { await h.diarizationIsIdle })
            if writerFailure { a.reject() }
            #expect(try await h.handle(f.packet(0, 0), requestID: UUID()) == .accepted)
            if writerFailure {
                #expect(await h.handle(f.barrier(1, 160, .finish), requestID: UUID()) == .accepted)
                try #require(await HPuntil { a.terminal }); #expect(a.commits.count == 1)
            } else {
                try await f.drain(h, a)
                #expect(await h.handle(.cut(scope: f.scope, nextPacketSequence: 1, sampleEnd: 160, reason: .deviceInterruption), requestID: UUID()) == .accepted)
            }
            await h.joinDiarizationRetirement(); #expect(a.count("shutdown") == 1)
            await f.cleanup(h)
        }
    }
    @Test func finalNativeTailCannotHoldMandatoryFinishOrPublishPadding() async throws {
        let f = HPfixture(), a = HPaudit(), finish = HPgate(), h = try await f.start(a, finish: finish)
        #expect(await h.handle(f.prepare, requestID: UUID()) == .accepted)
        try #require(await HPuntil { await h.diarizationIsIdle })
        #expect(try await h.handle(f.packet(0, 0, 161), requestID: UUID()) == .accepted); try await f.drain(h, a)
        #expect(await h.handle(f.barrier(1, 161, .finish), requestID: UUID()) == .accepted)
        try #require(await HPuntil { await finish.entered }); #expect(a.terminal && !a.retired)
        await finish.release(); try await f.drain(h, a); await h.joinDiarizationRetirement()
        #expect(a.rows.last?.samples.end == 161 && a.rows.count == 2 && a.count("diar-finish") == 1 && a.count("shutdown") == 1)
        await f.cleanup(h)
    }
    @Test func optionalAppendDoesNotRetainTheActualOriginalPacket() async throws {
        let f = HPfixture(), a = HPaudit(), append = HPgate(), vad = try VADLoadFixture(); defer { vad.cleanup() }
        let h = try await f.start(a, append: append, vad: vad, disposal: { _ in a.hit("original-disposed") })
        #expect(await h.handle(f.prepare, requestID: UUID()) == .accepted)
        try #require(await HPuntil { await h.diarizationIsIdle })
        #expect(try await h.handle(f.packet(0, 0, 3200), requestID: UUID()) == .accepted)
        try #require(await HPuntil { await append.entered })
        try #require(await HPuntil { a.count("original-disposed") == 1 })
        #expect(a.count("asr-append") == 1 && a.count("diar-append") == 1 && a.count("shutdown") == 0)
        #expect(await h.handle(.retireDiarization(identity: f.scope.identity, ownerID: f.owner), requestID: UUID()) == .accepted)
        #expect(!a.retired); await append.release(); await h.joinDiarizationRetirement()
        #expect(a.retired && a.count("shutdown") == 1); await f.cleanup(h)
    }
    @Test func optionalWriterRejectsAnActuallyHeldMandatoryLockAndUnsupportedFile() async throws {
        let f = HPfixture(), pipe = Pipe(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let w = LiveStdoutWriter(pipe.fileHandleForWriting, testingBeforeMandatoryWrite: { entered.signal(); release.wait() })
        w.claimSession(UUID())
        let worker = Task.detached { w.event(.finished(f.scope.identity)) }
        #expect(await Task.detached { HPsyncWait(entered) }.value == .success)
        let e = LiveDiarizationEvent(scope: f.scope, ownerID: f.owner, sequence: 0, payload: .preparing)
        #expect(!w.optional(e)) // Empty pipe; only the actual locked write rejects it.
        #expect(!w.optionalReply(UUID(), .rejected(.invalidConfiguration)))
        release.signal(); await worker.value
        let data = try #require(try LiveFrameReader.readChunk(from: pipe.fileHandleForReading))
        #expect(data.first! & 0x80 == 0)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("optional-output-\(UUID())")
        try Data().write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        let unsupported = LiveStdoutWriter(handle); unsupported.claimSession(UUID())
        #expect(!unsupported.optional(e))
        #expect(!unsupported.optionalReply(UUID(), .accepted))
        let saved = try Data(contentsOf: file); #expect(saved.isEmpty)
    }
    @Test func maximumPacketIsAnActualAtomicMacPipeFrameAndFullPipeDoesNotWait() throws {
        let f = HPfixture(), range = LiveSampleRange(start: Int64.max - 160, end: Int64.max)
        let row = try LiveDiarizationRow(streamSamples: range, samples: range, meeting: .init(startNanoseconds: Int64.max - 10_000_000, endNanoseconds: Int64.max), activity: [Float](repeating: 0.7, count: 8))
        let event = LiveDiarizationEvent(scope: f.scope, ownerID: f.owner, sequence: .max - 1, payload: .posterior(contextID: UUID(), rows: [row, row]))
        let pipe = Pipe(), w = LiveStdoutWriter(pipe.fileHandleForWriting); w.claimSession(UUID())
        #expect(w.optional(event))
        let data = try #require(try LiveFrameReader.readChunk(from: pipe.fileHandleForReading)), limit = fpathconf(pipe.fileHandleForWriting.fileDescriptor, _PC_PIPE_BUF)
        #expect(data.count <= limit && data.first! & 0x80 != 0)
        var mux = LiveOutputDemultiplexer(); var frames: [Data] = []
        #expect(try mux.feed(data) { frames.append($0) }.isEmpty)
        let env = try JSONDecoder().decode(EventEnvelope.self, from: try #require(frames.first))
        guard case .live(.event(.diarization(let decoded))) = env.event else { Issue.record("missing optional frame"); return }; #expect(decoded == event)
        let errors: [LiveProtocolError] = [.invalidConfiguration, .invalidPacket, .staleScope, .outOfOrder, .unavailable, .closed, .oversizedFrame, .outputLimit, .unsupportedRole]
        for reply in [LiveSessionReply.accepted] + errors.map({ .rejected($0) }) {
            let id = UUID(); #expect(w.optionalReply(id, reply))
            let raw = try #require(try LiveFrameReader.readChunk(from: pipe.fileHandleForReading))
            #expect(raw.count <= limit && raw.first! & 0x80 != 0)
            var demux = LiveOutputDemultiplexer(), bodies: [Data] = []
            #expect(try demux.feed(raw) { bodies.append($0) }.isEmpty && bodies.count == 1)
            let envelope = try JSONDecoder().decode(EventEnvelope.self, from: try #require(bodies.first))
            #expect(envelope.id == id)
            if case .live(.reply(let decoded)) = envelope.event { #expect(decoded == reply) }
            else { Issue.record("optional reply missing") }
        }
        let fd = pipe.fileHandleForWriting.fileDescriptor, flags = fcntl(fd, F_GETFL)
        #expect(fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0)
        let filler = [UInt8](repeating: 7, count: 512)
        while filler.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) > 0 {}
        #expect(errno == EAGAIN)
        #expect(fcntl(fd, F_SETFL, flags) == 0)
        #expect(!w.optional(event)) // Would hang here if write were blocking.
        #expect(!w.optionalReply(UUID(), .rejected(.invalidConfiguration)))
        #expect(fcntl(fd, F_GETFL) == flags)
    }

    @Test func actualDispatcherIsolatesEveryOptionalReplyAndKeepsCancelUntagged() async throws {
        let f = HPfixture(), audit = HPaudit(), helper = try await f.start(audit), pipe = Pipe()
        let writer = LiveStdoutWriter(pipe.fileHandleForWriting); writer.claimSession(UUID())
        var identity: LiveSessionIdentity? = f.scope.identity
        let context = UUID()
        let controls: [LiveSessionRequest] = [f.prepare,
            .acknowledgeDiarization(identity: f.scope.identity, ownerID: f.owner, contextID: context),
            .acknowledgeDiarizationPosterior(identity: f.scope.identity, ownerID: f.owner, contextID: context, sequence: 1),
            .retireDiarization(identity: f.scope.identity, ownerID: f.owner),
            .diarizationControl(.init(identity: f.scope.identity, ownerID: f.owner, payload: .prepare(epochID: f.scope.epochID))),
            .diarizationControl(.init(identity: f.scope.identity, ownerID: f.owner, payload: .acknowledge(contextID: context))),
            .diarizationControl(.init(identity: f.scope.identity, ownerID: f.owner, payload: .acknowledgePosterior(contextID: context, sequence: 1))),
            .diarizationControl(.init(identity: f.scope.identity, ownerID: f.owner, payload: .retire))]
        do {
            for control in controls {
                let id = UUID()
                await LiveRequestLoop.dispatch(.init(id: id, request: .live(control)), helper: helper, writer: writer, identity: &identity)
                let bytes = try #require(try LiveFrameReader.readChunk(from: pipe.fileHandleForReading))
                #expect(bytes.count <= fpathconf(pipe.fileHandleForWriting.fileDescriptor, _PC_PIPE_BUF))
                var mux = LiveOutputDemultiplexer(), optional: [Data] = []
                let mandatory = try mux.feed(bytes) { optional.append($0) }
                #expect(mandatory.isEmpty && optional.count == 1 && mux.retainedBytes == 0)
                if let body = optional.first {
                    let envelope = try JSONDecoder().decode(EventEnvelope.self, from: body)
                    #expect(envelope.id == id)
                    if case .live(.reply) = envelope.event {} else { Issue.record("optional reply missing") }
                }
                let fd = pipe.fileHandleForReading.fileDescriptor, flags = fcntl(fd, F_GETFL)
                #expect(fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0)
                var spare: UInt8 = 0
                #expect(Darwin.read(fd, &spare, 1) == -1 && errno == EAGAIN) // No untagged finished frame.
                #expect(fcntl(fd, F_SETFL, flags) == 0)
            }
            let cancelID = UUID()
            await LiveRequestLoop.dispatch(.init(id: cancelID, request: .live(.cancel(f.scope.identity))), helper: helper, writer: writer, identity: &identity)
            let bytes = try #require(try LiveFrameReader.readChunk(from: pipe.fileHandleForReading))
            var mux = LiveOutputDemultiplexer(), optionalCount = 0
            let mandatory = try mux.feed(bytes) { _ in optionalCount += 1 }
            var reader = LiveFrameReader()
            let replies = try reader.feed(mandatory).map { try JSONDecoder().decode(EventEnvelope.self, from: $0) }
            #expect(optionalCount == 0 && replies.count == 2 && replies.allSatisfy { $0.id == cancelID })
            if replies.count == 2 {
                if case .live(.reply(.accepted)) = replies[0].event {} else { Issue.record("mandatory cancel reply missing") }
                if case .finished = replies[1].event {} else { Issue.record("mandatory finished missing") }
            }
            await helper.joinDiarizationRetirement()
        } catch { await f.cleanup(helper); throw error }
        await f.cleanup(helper)
    }

    @Test(arguments: [false, true])
    func frozenCompactPrepareUsesOnlyExactBeginConfigurationAndNeverHoldsASR(frozen: Bool) async throws {
        let f = HPfixture(), audit = HPaudit(), load = HPgate(), shutdown = HPgate()
        let helper = try await f.start(audit, load: load, shutdown: shutdown, frozen: frozen)
        func control(_ owner: UUID, _ identity: LiveSessionIdentity, _ epoch: UUID) -> LiveSessionRequest {
            .diarizationControl(.init(identity: identity, ownerID: owner, payload: .prepare(epochID: epoch)))
        }
        do {
            #expect(audit.count("load") == 0 && audit.configuration == nil && audit.events.isEmpty)
            let foreignCapture = LiveSessionIdentity(recordingID: f.scope.identity.recordingID, captureSessionID: UUID())
            for request in [control(UUID(), f.scope.identity, f.scope.epochID),
                            control(f.owner, foreignCapture, f.scope.epochID), control(f.owner, f.scope.identity, UUID())] {
                #expect(await helper.handle(request, requestID: UUID()) == .rejected(.staleScope))
            }
            #expect(audit.count("load") == 0 && audit.events.isEmpty)
            let reply = await helper.handle(control(f.owner, f.scope.identity, f.scope.epochID), requestID: UUID())
            if frozen {
                #expect(reply == .accepted); try #require(await HPuntil { await load.entered })
                #expect(audit.configuration == f.configuration && audit.count("load") == 1)
            } else { #expect(reply == .rejected(.staleScope) && audit.count("load") == 0) }
            #expect(try await helper.handle(f.packet(0, 0), requestID: UUID()) == .accepted)
            #expect(await helper.handle(f.barrier(1, 160, .finish), requestID: UUID()) == .accepted)
            try #require(await HPuntil { audit.terminal })
            #expect(audit.commits.count == 1 && audit.commits[0].text == "unchanged ASR" && audit.commits[0].diarizerContextID == nil)
            if frozen {
                #expect(!audit.retired); await load.release()
                try #require(await HPuntil { await shutdown.entered })
                #expect(!audit.retired && audit.count("shutdown") == 1 && audit.count("driver-dead") == 0)
                await shutdown.release(); await helper.joinDiarizationRetirement()
                #expect(audit.retired && audit.count("shutdown") == 1)
            }
            await f.cleanup(helper)
        } catch { await load.release(); await shutdown.release(); await f.cleanup(helper); throw error }
    }

    @Test func independentCompactWireOracleRejectsMalformedEvidence() throws {
        // Handcrafted version/kind, four RFC UUIDs, UInt64LE sequence, context,
        // count and one160-sample row with eight independent Float32LE0.5 values.
        // None of these bytes come from the production binary encoder.
        let ids = Array(UInt8(1)...UInt8(64))
        let header = [UInt8(1), 2] + ids + [3, 0, 0, 0, 0, 0, 0, 0]
        let row = [UInt8](repeating: 0, count: 16) + [160, 0, 0] + Array(repeating: [UInt8](arrayLiteral: 0, 0, 0, 63), count: 8).flatMap { $0 }
        let valid = header + Array(UInt8(65)...UInt8(80)) + [1] + row
        func decode(_ bytes: [UInt8]) throws -> LiveDiarizationEvent {
            let json = try JSONSerialization.data(withJSONObject: Data(bytes).base64EncodedString(), options: .fragmentsAllowed)
            return try JSONDecoder().decode(LiveDiarizationEvent.self, from: json)
        }
        let decoded = try decode(valid)
        #expect(decoded.sequence == 3 && decoded.scope.source == .system)
        #expect(decoded.scope.identity.recordingID == UUID(uuidString: "01020304-0506-0708-090A-0B0C0D0E0F10"))
        #expect(decoded.scope.identity.captureSessionID == UUID(uuidString: "11121314-1516-1718-191A-1B1C1D1E1F20"))
        #expect(decoded.scope.epochID == UUID(uuidString: "21222324-2526-2728-292A-2B2C2D2E2F30"))
        #expect(decoded.ownerID == UUID(uuidString: "31323334-3536-3738-393A-3B3C3D3E3F40"))
        if case .posterior(let context, let rows) = decoded.payload {
            #expect(context == UUID(uuidString: "41424344-4546-4748-494A-4B4C4D4E4F50"))
            #expect(rows.count == 1 && rows[0].samples == .init(start: 0, end: 160))
            #expect(try rows[0].activityValues() == [Float](repeating: 0.5, count: 8))
        } else { Issue.record("independent posterior missing") }
        var malformed = (0..<valid.count).map { Array(valid.prefix($0)) }
        malformed += [valid + [0], [UInt8](repeating: 0, count: 210)]
        for (index, value): (Int, UInt8) in [(0, 2), (1, 4), (90, 0), (90, 3), (109, 2), (107, 0), (107, 161), (98, 128), (106, 128)] {
            var bytes = valid; bytes[index] = value; malformed.append(bytes)
        }
        var badSequence = valid; badSequence.replaceSubrange(66..<74, with: [UInt8](repeating: 255, count: 8)); malformed.append(badSequence)
        for bits: [UInt8] in [[0, 0, 192, 127], [0, 0, 128, 127], [0, 0, 128, 191], [0, 0, 0, 64]] {
            var bytes = valid; bytes.replaceSubrange(110..<114, with: bits); malformed.append(bytes)
        }
        var meetingOverflow = Array(valid.prefix(110)); meetingOverflow[109] = 1
        meetingOverflow += [255, 255, 255, 255, 255, 255, 255, 127] + Array(valid.suffix(32)); malformed.append(meetingOverflow)
        var ready = header; ready[1] = 1; ready += [0, 0, 0, 0, 0, 0, 0, 128] + Array(repeating: 5, count: 16); malformed.append(ready)
        var retired = header; retired[1] = 3; retired += [0] + Array(repeating: 6, count: 16) + [0]
        var badFlag = retired; badFlag[74] = 2; malformed.append(badFlag)
        var badReason = retired; badReason[91] = 7; malformed.append(badReason)
        for (index, bytes) in malformed.enumerated() {
            do { _ = try decode(bytes); Issue.record("malformed compact body accepted: \(index)") } catch {}
        }
    }
}
