import Foundation
import Testing
import dBriefWire
@testable import dBriefMLHost

private actor DiarizationGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    func wait() async {
        entered = true
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; let held = waiters; waiters = []; for w in held { w.resume() } }
}
private final class DiarizationAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func hit(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }
}
private final class DiarizationWitness: LiveDiarizationResourceWitness {
    let audit: DiarizationAudit
    init(_ audit: DiarizationAudit) { self.audit = audit }
    deinit { audit.hit("witness-dead") }
}
private actor DiarizationDriver: LiveDiarizationDriving {
    let audit: DiarizationAudit
    let mode: String
    let appendGate: DiarizationGate?
    let shutdownGate: DiarizationGate?
    private var samples = 0, emitted = 0
    init(_ audit: DiarizationAudit, mode: String, appendGate: DiarizationGate? = nil, shutdownGate: DiarizationGate? = nil) {
        self.audit = audit; self.mode = mode; self.appendGate = appendGate; self.shutdownGate = shutdownGate
    }
    deinit { audit.hit("driver-dead") }
    func append(_ samples: [Float]) async throws -> [LiveDiarizationChunk] {
        audit.hit("append"); self.samples += samples.count
        await appendGate?.wait() // Deliberately ignores cancellation.
        if mode == "throw" { throw CocoaError(.fileReadUnknown) }
        if mode == "none" { return [] }
        if mode == "bad-slots" { return [.init(frameCount: 1, numSpeakers: 7, probabilities: [Float](repeating: 0.9, count: 7))] }
        if mode == "bad-probability" { return [.init(frameCount: 1, probabilities: [Float](repeating: .nan, count: 8))] }
        if mode == "bad-flood" { return [LiveDiarizationChunk](repeating: .init(frameCount: 0, probabilities: []), count: 65) }
        if mode == "bad-tail" { return [.init(frameCount: 1, probabilities: [Float](repeating: 0.7, count: 8)), .init(frameCount: 1, probabilities: [])] }
        if mode == "ahead" { return [.init(frameCount: 20, probabilities: [Float](repeating: 0.7, count: 160))] }
        if mode == "pause-tail", self.samples < 160 { return [] }
        let count = self.samples / 160 - emitted; emitted += count
        return count == 0 ? [] : [.init(frameCount: count, probabilities: [Float](repeating: 0.7, count: count * 8))]
    }
    func finish() async throws -> [LiveDiarizationChunk] {
        audit.hit("finish")
        if mode == "finish-throw" { throw CocoaError(.fileReadUnknown) }
        let count = (samples + 159) / 160 + (samples > 0 ? 1 : 0) - emitted
        emitted += count
        return count == 0 ? [] : [.init(frameCount: count, probabilities: [Float](repeating: 0.8, count: count * 8))]
    }
    func shutdown() async { audit.hit("shutdown"); await shutdownGate?.wait() }
}
private struct DiarizationFixture: Sendable {
    let identity = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
    let epoch = UUID()
    func scope(epoch: UUID? = nil, source: LiveSource = .system) -> LiveLaneScope {
        .init(identity: identity, source: source, epochID: epoch ?? self.epoch)
    }
    func owner(_ audit: DiarizationAudit, mode: String = "normal", preset: LiveDiarizationPreset = .low,
               load: DiarizationGate? = nil, append: DiarizationGate? = nil, shutdown: DiarizationGate? = nil) throws -> LiveDiarizationSession {
        try .init(scope: scope(), preset: preset, witness: DiarizationWitness(audit)) {
            audit.hit("load"); await load?.wait()
            return DiarizationDriver(audit, mode: mode, appendGate: append, shutdownGate: shutdown)
        }
    }
    func meeting(_ count: Int, start: Int64 = 0) -> LiveMeetingRange { .init(startNanoseconds: start, endNanoseconds: start + Int64(count) * 62_500) }
    func text(scope: LiveLaneScope? = nil, count: Int64 = 160, meeting: LiveMeetingRange? = nil, context: UUID? = nil) -> CommittedLiveSegment {
        let scope = scope ?? self.scope()
        return .init(id: .init(epochID: scope.epochID, index: 7), source: scope.source,
            range: .init(samples: .init(start: 0, end: count), meeting: meeting), text: "same ü words",
            words: [.init(text: "same", samples: nil, confidence: 1)], language: "en", diarizerContextID: context)
    }
}
private func diarizationEventually(_ predicate: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<1_000 { if await predicate() { return true }; try? await Task.sleep(for: .milliseconds(2)) }
    return false
}
private func diarizationRejects(_ expected: LiveDiarizationSession.Failure, _ body: () async throws -> Void) async {
    do { try await body(); Issue.record("Expected \(expected)") }
    catch { #expect(error as? LiveDiarizationSession.Failure == expected) }
}

@Suite struct LiveDiarizationContinuityTests {
    @Test func contextSurvivesUtterancesAndPauseWithoutFinishingTheDriver() async throws {
        let f = DiarizationFixture(), a = DiarizationAudit(), s = try f.owner(a)
        let context = try await s.prepare()
        for index in 0..<3 {
            let t = try await s.admit(scope: f.scope(), samples: [Float](repeating: 0, count: 160), startSample: Int64(index * 160), meeting: f.meeting(160, start: Int64(index) * 10_000_000))
            let b = try await s.complete(t)
            #expect(b.frames.count == 1 && b.frames[0].contextID == context)
            #expect(try await s.utteranceBoundary(scope: f.scope()) == context)
        }
        #expect(try await s.pause(scope: f.scope()) == context)
        let next = f.scope(epoch: UUID())
        #expect(try await s.resume(previous: f.scope(), next: next) == context)
        #expect(a.count("load") == 1 && a.count("append") == 3 && a.count("finish") == 0)
        let v = await s.snapshot(); #expect(v.streamSampleEnd == 480 && v.nativeFrameEnd == 3 && v.epochCount == 2)
        await s.retire(); await s.joinRetirement()
        #expect(a.count("shutdown") == 1)
    }
    @Test func pauseTailSplitsOneNativeFrameAndNeverFillsTheMeetingGap() async throws {
        let f = DiarizationFixture(), a = DiarizationAudit(), s = try f.owner(a, mode: "pause-tail")
        _ = try await s.prepare()
        let first = try await s.admit(scope: f.scope(), samples: [Float](repeating: 0, count: 80), startSample: 0, meeting: f.meeting(80))
        #expect(try await s.complete(first).frames.isEmpty)
        _ = try await s.pause(scope: f.scope()); let next = f.scope(epoch: UUID())
        _ = try await s.resume(previous: f.scope(), next: next)
        let second = try await s.admit(scope: next, samples: [Float](repeating: 0, count: 80), startSample: 0, meeting: f.meeting(80, start: 5_000_000_000))
        let b = try await s.complete(second)
        #expect(b.frames.count == 2)
        #expect(b.frames.map(\.samples) == [.init(start: 0, end: 80), .init(start: 0, end: 80)])
        #expect(b.frames.map(\.meeting) == [f.meeting(80), f.meeting(80, start: 5_000_000_000)])
        #expect(b.frames.map(\.scope) == [f.scope(), next])
        #expect(b.frames.allSatisfy { $0.activity == [Float](repeating: 0.7, count: 8) })
        await s.retire(); await s.joinRetirement()
    }
    @Test func finalPaddingIsClippedAndRepeatedFinishHasNoPublishableRows() async throws {
        let f = DiarizationFixture(), a = DiarizationAudit(), s = try f.owner(a)
        _ = try await s.prepare()
        let t = try await s.admit(scope: f.scope(), samples: [Float](repeating: 0, count: 161), startSample: 0, meeting: f.meeting(161))
        #expect(try await s.complete(t).frames.count == 1)
        let b = try await s.finish(scope: f.scope()), replay = try await s.finish(scope: f.scope())
        #expect(b.frames.count == 1 && b.frames[0].samples == .init(start: 160, end: 161))
        #expect(b.frames[0].meeting == f.meeting(1, start: 10_000_000))
        #expect(b.nativeFrameEnd == 3 && b.streamSampleEnd == 161 && !b.replay)
        #expect(replay.token == b.token && replay.nativeFrameEnd == b.nativeFrameEnd && replay.frames.isEmpty && replay.replay)
        #expect(a.count("finish") == 1)
        await diarizationRejects(.inactive) { _ = try await s.admit(scope: f.scope(), samples: [0], startSample: 161, meeting: nil) }
        await s.retire(); await s.joinRetirement()
    }
    @Test func attachmentChangesOnlyContextAndKeepsExactOldEpochAuthority() async throws {
        let f = DiarizationFixture(), a = DiarizationAudit(), s = try f.owner(a)
        let context = try await s.prepare()
        let t = try await s.admit(scope: f.scope(), samples: [Float](repeating: 0, count: 160), startSample: 0, meeting: f.meeting(160))
        let original = f.text(meeting: f.meeting(160))
        #expect(try await s.attachingContext(to: original, scope: f.scope()) == f.text(meeting: f.meeting(160), context: context))
        #expect(original.diarizerContextID == nil)
        _ = try await s.complete(t); _ = try await s.pause(scope: f.scope())
        let next = f.scope(epoch: UUID()); _ = try await s.resume(previous: f.scope(), next: next)
        #expect(try await s.attachingContext(to: original, scope: f.scope()).diarizerContextID == context)
        await diarizationRejects(.staleScope) { _ = try await s.attachingContext(to: original, scope: next) }
        await diarizationRejects(.staleScope) { _ = try await s.attachingContext(to: f.text(context: UUID()), scope: f.scope()) }
        await diarizationRejects(.invalidInput) { _ = try await s.attachingContext(to: f.text(count: 161), scope: f.scope()) }
        await diarizationRejects(.invalidInput) { _ = try await s.attachingContext(to: f.text(meeting: f.meeting(160, start: 1)), scope: f.scope()) }
        let foreign = DiarizationFixture().scope()
        await diarizationRejects(.staleScope) { _ = try await s.attachingContext(to: original, scope: foreign) }
        await s.retire(); await s.joinRetirement()
        await diarizationRejects(.inactive) { _ = try await s.attachingContext(to: original, scope: f.scope()) }
        let fresh = try f.owner(a); _ = try await fresh.prepare()
        #expect(fresh.contextID != context)
        await diarizationRejects(.staleScope) { _ = try await fresh.attachingContext(to: f.text(context: context), scope: f.scope()) }
        await fresh.retire(); await fresh.joinRetirement()
    }
    @Test func unknownClockDoesNotAcquireAnInventedMeetingRange() async throws {
        let f = DiarizationFixture(), a = DiarizationAudit(), s = try f.owner(a)
        _ = try await s.prepare()
        let t = try await s.admit(scope: f.scope(), samples: [Float](repeating: 0, count: 160), startSample: 0, meeting: nil)
        #expect(try await s.complete(t).frames.allSatisfy { $0.meeting == nil })
        #expect(try await s.attachingContext(to: f.text(), scope: f.scope()).range.meeting == nil)
        await diarizationRejects(.invalidInput) { _ = try await s.attachingContext(to: f.text(meeting: f.meeting(160)), scope: f.scope()) }
        await s.retire(); await s.joinRetirement()
    }
    @Test(arguments: ["bad-slots", "bad-probability", "bad-flood", "bad-tail", "ahead", "throw"])
    func malformedOutputRetiresOnlyThisOptionalOwnerAtomically(mode: String) async throws {
        let f = DiarizationFixture(), a = DiarizationAudit(), s = try f.owner(a, mode: mode)
        _ = try await s.prepare()
        let t = try await s.admit(scope: f.scope(), samples: [Float](repeating: 0, count: 160), startSample: 0, meeting: nil)
        do { _ = try await s.complete(t); Issue.record("Malformed output accepted") } catch {}
        let v = await s.snapshot(); #expect(v.phase == .retired && v.nativeFrameEnd == 0)
        await s.joinRetirement(); #expect(a.count("shutdown") == 1)
    }
    @Test(arguments: LiveDiarizationPreset.allCases)
    func missingProgressHitsThePresetBoundAndCannotRevive(preset: LiveDiarizationPreset) async throws {
        let f = DiarizationFixture(), a = DiarizationAudit(), s = try f.owner(a, mode: "none", preset: preset)
        _ = try await s.prepare()
        var count: Int64 = 0
        while count + 3_200 <= preset.pendingSampleLimit {
            let t = try await s.admit(scope: f.scope(), samples: [Float](repeating: 0, count: 3_200), startSample: count, meeting: nil)
            _ = try await s.complete(t); count += 3_200
        }
        await diarizationRejects(.capacity) { _ = try await s.admit(scope: f.scope(), samples: [Float](repeating: 0, count: 3_200), startSample: count, meeting: nil) }
        let v = await s.snapshot(); #expect(v.phase == .retired && v.streamSampleEnd == count && v.pendingSamples <= preset.pendingSampleLimit)
        await s.joinRetirement()
        await diarizationRejects(.inactive) { _ = try await s.prepare() }
    }
    @Test func fullEpochInventoryIncludesEmptyResumesAndCannotReuseAnOldUUID() async throws {
        let f = DiarizationFixture(), a = DiarizationAudit(), s = try f.owner(a)
        _ = try await s.prepare(); var prior = f.scope()
        for _ in 1..<64 {
            _ = try await s.pause(scope: prior); let next = f.scope(epoch: UUID())
            if prior != f.scope() { await diarizationRejects(.invalidInput) { _ = try await s.resume(previous: prior, next: f.scope()) } }
            _ = try await s.resume(previous: prior, next: next); prior = next
        }
        _ = try await s.pause(scope: prior)
        await diarizationRejects(.capacity) { _ = try await s.resume(previous: prior, next: f.scope(epoch: UUID())) }
        let v = await s.snapshot(); #expect(v.phase == .retired && v.epochCount == 64 && v.pieceCount == 0)
        #expect(a.count("append") == 0 && a.count("finish") == 0)
        await s.joinRetirement()
    }
    @Test func invalidAdmissionDoesNotSpendSamplesOrInvokeNativeCode() async throws {
        let f = DiarizationFixture(), a = DiarizationAudit(), s = try f.owner(a)
        _ = try await s.prepare()
        for samples in [[], [Float.nan], [Float](repeating: 0, count: 3_201)] {
            await diarizationRejects(.invalidInput) { _ = try await s.admit(scope: f.scope(), samples: samples, startSample: 0, meeting: nil) }
        }
        await diarizationRejects(.invalidInput) { _ = try await s.admit(scope: f.scope(), samples: [0], startSample: 1, meeting: nil) }
        await diarizationRejects(.invalidInput) { _ = try await s.admit(scope: f.scope(), samples: [0], startSample: 0, meeting: f.meeting(2)) }
        await diarizationRejects(.staleScope) { _ = try await s.admit(scope: f.scope(source: .microphone), samples: [0], startSample: 0, meeting: nil) }
        let v = await s.snapshot(); #expect(v.streamSampleEnd == 0 && v.phase == .active && a.count("append") == 0)
        let t = try await s.admit(scope: f.scope(), samples: [0], startSample: 0, meeting: f.meeting(1))
        _ = try await s.complete(t)
        await diarizationRejects(.invalidInput) { _ = try await s.admit(scope: f.scope(), samples: [0], startSample: 1, meeting: f.meeting(1, start: 62_501)) }
        await diarizationRejects(.invalidInput) { _ = try await s.admit(scope: f.scope(), samples: [0], startSample: 1, meeting: nil) }
        await s.retire(); await s.joinRetirement()
    }
    @Test func heldAppendHasNoQueueAndResourcesSurviveCanceledCompletionAndShutdown() async throws {
        let f = DiarizationFixture(), a = DiarizationAudit(), append = DiarizationGate(), shutdown = DiarizationGate()
        let s = try f.owner(a, append: append, shutdown: shutdown); _ = try await s.prepare()
        let t = try await s.admit(scope: f.scope(), samples: [Float](repeating: 0, count: 160), startSample: 0, meeting: nil)
        let completion = Task { try? await s.complete(t) }
        #expect(await diarizationEventually { await append.entered })
        await diarizationRejects(.busy) { _ = try await s.admit(scope: f.scope(), samples: [0], startSample: 160, meeting: nil) }
        await diarizationRejects(.busy) { _ = try await s.pause(scope: f.scope()) }
        let v = await s.snapshot(); #expect(v.streamSampleEnd == 160 && v.hasWork && a.count("append") == 1)
        completion.cancel()
        #expect(await diarizationEventually { await s.snapshot().phase == .retired })
        await diarizationRejects(.inactive) { _ = try await s.attachingContext(to: f.text(), scope: f.scope()) }
        await diarizationRejects(.inactive) { _ = try await s.admit(scope: f.scope(), samples: [0], startSample: 160, meeting: nil) }
        let join = Task { await s.joinRetirement(); a.hit("joined") }
        join.cancel()
        let peer = Task { await s.joinRetirement(); a.hit("peer-joined") }
        #expect(a.count("witness-dead") == 0 && a.count("driver-dead") == 0 && a.count("shutdown") == 0)
        await append.release(); _ = await completion.value
        #expect(await diarizationEventually { await shutdown.entered })
        #expect(a.count("joined") == 0 && a.count("peer-joined") == 0 && a.count("witness-dead") == 0 && a.count("driver-dead") == 0)
        await shutdown.release(); await join.value; await peer.value
        #expect(await diarizationEventually { a.count("driver-dead") == 1 && a.count("witness-dead") == 1 })
        #expect(a.count("shutdown") == 1)
        let ended = await s.snapshot(); #expect(ended.phase == .retired && !ended.hasWork && !ended.resourcesHeld && ended.nativeFrameEnd == 0)
    }
    @Test func retiredPreparationStillDisposesItsActuallyReturnedDriverBeforeRelease() async throws {
        let f = DiarizationFixture(), a = DiarizationAudit(), load = DiarizationGate(), shutdown = DiarizationGate()
        let s = try f.owner(a, load: load, shutdown: shutdown)
        let preparation = Task { try? await s.prepare() }
        #expect(await diarizationEventually { await load.entered })
        preparation.cancel()
        #expect(await diarizationEventually { await s.snapshot().phase == .retired })
        await diarizationRejects(.inactive) { _ = try await s.attachingContext(to: f.text(), scope: f.scope()) }
        await diarizationRejects(.inactive) { _ = try await s.admit(scope: f.scope(), samples: [0], startSample: 0, meeting: nil) }
        let join = Task { await s.joinRetirement(); a.hit("joined") }
        #expect(a.count("witness-dead") == 0 && a.count("shutdown") == 0)
        await load.release(); _ = await preparation.value
        #expect(await diarizationEventually { await shutdown.entered })
        #expect(a.count("witness-dead") == 0 && a.count("driver-dead") == 0 && a.count("joined") == 0)
        await shutdown.release(); await join.value
        #expect(await diarizationEventually { a.count("witness-dead") == 1 && a.count("driver-dead") == 1 })
        #expect(a.count("load") == 1 && a.count("shutdown") == 1)
    }
    @Test func exactSixtyFourRecordedPiecesKeepEveryObservedSampleAndClockGap() async throws {
        let f = DiarizationFixture(), a = DiarizationAudit(), s = try f.owner(a, mode: "none")
        _ = try await s.prepare(); var prior = f.scope()
        for index in 0..<64 {
            if index > 0 {
                _ = try await s.pause(scope: prior); let next = f.scope(epoch: UUID())
                _ = try await s.resume(previous: prior, next: next); prior = next
            }
            let t = try await s.admit(scope: prior, samples: [0], startSample: 0, meeting: f.meeting(1, start: Int64(index) * 100_000_000))
            _ = try await s.complete(t)
        }
        let b = try await s.finish(scope: prior)
        #expect(b.frames.count == 64 && b.streamSampleEnd == 64 && b.nativeFrameEnd == 2)
        #expect(b.frames.enumerated().allSatisfy { i, row in
            row.streamSamples == .init(start: Int64(i), end: Int64(i + 1)) && row.samples == .init(start: 0, end: 1) &&
                row.meeting == f.meeting(1, start: Int64(i) * 100_000_000) && row.activity == [Float](repeating: 0.8, count: 8)
        })
        await s.retire(); await s.joinRetirement()
    }
    @Test func backwardClockAfterPauseAndRepeatedTokensRejectBeforeMutation() async throws {
        let f = DiarizationFixture(), a = DiarizationAudit(), s = try f.owner(a)
        _ = try await s.prepare()
        let t = try await s.admit(scope: f.scope(), samples: [Float](repeating: 0, count: 160), startSample: 0, meeting: f.meeting(160, start: 1_000_000_000))
        _ = try await s.complete(t)
        await diarizationRejects(.staleScope) { _ = try await s.complete(t) }
        _ = try await s.pause(scope: f.scope()); let next = f.scope(epoch: UUID())
        _ = try await s.resume(previous: f.scope(), next: next)
        await diarizationRejects(.invalidInput) { _ = try await s.admit(scope: next, samples: [0], startSample: 0, meeting: f.meeting(1)) }
        let v = await s.snapshot(); #expect(v.streamSampleEnd == 160 && v.pieceCount == 1 && a.count("append") == 1)
        await s.retire(); await s.joinRetirement()
    }
    @Test func failedFactoryAndTerminalNativeFailureRetireWithoutRetainedErrors() async throws {
        let f = DiarizationFixture(), a = DiarizationAudit()
        let failed = try LiveDiarizationSession(scope: f.scope(), preset: .low, witness: DiarizationWitness(a)) { throw CocoaError(.fileReadUnknown) }
        await diarizationRejects(.failed) { _ = try await failed.prepare() }
        await failed.joinRetirement()
        #expect(a.count("witness-dead") == 1 && a.count("shutdown") == 0)
        let s = try f.owner(a, mode: "finish-throw"); _ = try await s.prepare()
        await diarizationRejects(.failed) { _ = try await s.finish(scope: f.scope()) }
        await s.joinRetirement()
        #expect(a.count("witness-dead") == 2 && a.count("driver-dead") == 1 && a.count("shutdown") == 1)
    }
}
