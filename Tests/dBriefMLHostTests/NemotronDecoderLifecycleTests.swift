import Foundation
import Testing
@testable import dBriefMLHost

private final class DecoderEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NemotronDecoderEvent] = []
    func append(_ value: NemotronDecoderEvent) { lock.withLock { storage.append(value) } }
    var values: [NemotronDecoderEvent] { lock.withLock { storage } }
    var commits: [NemotronCommittedUtterance] {
        values.compactMap { if case .committed(let value) = $0 { value } else { nil } }
    }
    var partials: [String] {
        values.compactMap { if case .partial(_, let value) = $0 { value } else { nil } }
    }
}

private actor FixtureDecoder: NemotronStreamingDecoder {
    nonisolated let partial: @Sendable (String) -> Void
    let started: LifetimeSignal?
    let release: LifetimeSignal?
    let failFinish: Bool
    let badAccounting: Bool
    private var samples: [Float] = []
    init(partial: @escaping @Sendable (String) -> Void, started: LifetimeSignal? = nil,
         release: LifetimeSignal? = nil, failFinish: Bool = false, badAccounting: Bool = false) {
        self.partial = partial; self.started = started; self.release = release
        self.failFinish = failFinish; self.badAccounting = badAccounting
    }
    func process(samples: [Float]) async throws -> NemotronDecoderProgress {
        await started?.signal()
        await release?.wait()
        self.samples += samples
        partial(self.samples.map { String(Int($0)) }.joined(separator: " "))
        return .init(consumedSamples: badAccounting ? 99 : 0, heldSamples: Int64(self.samples.count))
    }
    func finish() async throws -> NemotronDecoderOutput {
        if failFinish { throw NemotronSessionError.unavailable }
        return .init(text: samples.map { String(Int($0)) }.joined(separator: " "), timings: [])
    }
}

actor FixtureFactory: NemotronDecoderMaking {
    let failAt: Int?
    let started: LifetimeSignal?
    let release: LifetimeSignal?
    let failFinish: Bool
    let badAccounting: Bool
    private var calls = 0
    private var decoders: [FixtureDecoder] = []
    init(failAt: Int? = nil, started: LifetimeSignal? = nil, release: LifetimeSignal? = nil,
         failFinish: Bool = false, badAccounting: Bool = false) {
        self.failAt = failAt; self.started = started; self.release = release
        self.failFinish = failFinish; self.badAccounting = badAccounting
    }
    func makeDecoder(configuration: NemotronDecoderConfiguration,
                     partial: @escaping @Sendable (String) -> Void) async throws -> any NemotronStreamingDecoder {
        calls += 1
        if calls == failAt { throw NemotronSessionError.unavailable }
        let decoder = FixtureDecoder(partial: partial, started: started, release: release,
                                     failFinish: failFinish, badAccounting: badAccounting)
        decoders.append(decoder)
        return decoder
    }
    func oldCallback() -> @Sendable (String) -> Void { decoders[0].partial }
}

@Suite struct NemotronDecoderLifecycleTests {
    @Test func freshUtteranceDoesNotReuseTokensAndRejectsRetiredCallbacks() async throws {
        let factory = FixtureFactory(), events = DecoderEvents()
        let lane = NemotronDecoderSession(factory: factory, emit: events.append)
        try await lane.prepare(configuration: .init(language: .nl))
        try await lane.append(samples: [1, 2], startSample: 0)
        let oldPartial = await factory.oldCallback()
        let first = try await lane.finish()
        oldPartial("retired text")
        try await lane.append(samples: [3], startSample: 2)
        let second = try await lane.finish(replacingDecoder: false)
        #expect(first.output.text == "1 2")
        #expect(second.output.text == "3")
        #expect(first.generation != second.generation)
        #expect(first.range == 0..<2)
        #expect(second.range == 2..<3)
        #expect(events.partials == ["1 2", "3"])
        #expect(events.commits.map(\.output.text) == ["1 2", "3"])
    }

    @Test func replacementFailurePreservesCommitAndReportsUnavailableInput() async throws {
        let events = DecoderEvents()
        let lane = NemotronDecoderSession(factory: FixtureFactory(failAt: 2), emit: events.append)
        try await lane.prepare(configuration: .init(language: .en))
        try await lane.append(samples: [7], startSample: 0)
        await #expect(throws: NemotronSessionError.unavailable) { try await lane.finish() }
        await #expect(throws: NemotronSessionError.unavailable) {
            try await lane.append(samples: [8, 9], startSample: 1)
        }
        #expect(events.commits.map(\.output.text) == ["7"])
        #expect(events.values.filter { if case .ready = $0 { true } else { false } }.count == 1)
        #expect(events.values.contains(.gap(1..<3)))
    }

    @Test func finishCannotOvertakeSuspendedProcess() async throws {
        let started = LifetimeSignal(), release = LifetimeSignal(), events = DecoderEvents()
        let lane = NemotronDecoderSession(factory: FixtureFactory(started: started, release: release), emit: events.append)
        try await lane.prepare(configuration: .init(language: .auto))
        let processing = Task { try await lane.append(samples: [4], startSample: 0) }
        await started.wait()
        let finishing = Task { try await lane.finish(replacingDecoder: false) }
        await release.signal()
        try await processing.value
        #expect(try await finishing.value.output.text == "4")
        #expect(events.values.firstIndex { if case .partial = $0 { true } else { false } }!
            < events.values.firstIndex { if case .committed = $0 { true } else { false } }!)
    }

    @Test func oneLaneFailureCannotRetireAnotherLanesState() async throws {
        let firstEvents = DecoderEvents(), secondEvents = DecoderEvents()
        let first = NemotronDecoderSession(factory: FixtureFactory(failAt: 1), emit: firstEvents.append)
        let second = NemotronDecoderSession(factory: FixtureFactory(), emit: secondEvents.append)
        await #expect(throws: NemotronSessionError.unavailable) { try await first.prepare(configuration: .init(language: .nl)) }
        try await second.prepare(configuration: .init(language: .en), origin: 10)
        try await second.append(samples: [5], startSample: 10)
        #expect(try await second.finish(replacingDecoder: false).output.text == "5")
        #expect(firstEvents.commits.isEmpty)
        #expect(secondEvents.commits.first?.range == 10..<11)
    }

    @Test func finishFailureMarksWholeProvisionalRangeMissing() async throws {
        let events = DecoderEvents()
        let lane = NemotronDecoderSession(factory: FixtureFactory(failFinish: true), emit: events.append)
        try await lane.prepare(configuration: .init(language: .auto), origin: 20)
        try await lane.append(samples: [1, 2, 3], startSample: 20)
        await #expect(throws: NemotronSessionError.unavailable) { try await lane.finish() }
        #expect(events.commits.isEmpty)
        #expect(events.values.contains(.gap(20..<23)))
    }

    @Test func bufferedInputIsNotPublishedAsCommittedEvidence() async throws {
        let events = DecoderEvents()
        let lane = NemotronDecoderSession(factory: FixtureFactory(), emit: events.append)
        try await lane.prepare(configuration: .init(language: .en))
        try await lane.append(samples: [1, 2], startSample: 0)
        #expect(events.commits.isEmpty)
        #expect(events.values.contains { if case .progress(_, let p) = $0 { p.consumedSamples == 0 && p.heldSamples == 2 } else { false } })
    }

    @Test func impossibleNativeAccountingCannotProduceACommit() async throws {
        let events = DecoderEvents()
        let lane = NemotronDecoderSession(factory: FixtureFactory(badAccounting: true), emit: events.append)
        try await lane.prepare(configuration: .init(language: .nl))
        await #expect(throws: NemotronSessionError.invalidAccounting) { try await lane.append(samples: [1], startSample: 0) }
        #expect(events.commits.isEmpty)
        #expect(events.values.contains(.gap(0..<1)))
    }

    @Test func invalidAndDiscontinuousPacketsNeverEnterDecoder() async throws {
        let events = DecoderEvents()
        let lane = NemotronDecoderSession(factory: FixtureFactory(), emit: events.append)
        try await lane.prepare(configuration: .init(language: .auto))
        await #expect(throws: NemotronSessionError.invalidPacket) { try await lane.append(samples: [.nan], startSample: 0) }
        await #expect(throws: NemotronSessionError.invalidPacket) { try await lane.append(samples: [1], startSample: 2) }
        try await lane.append(samples: [6], startSample: 0)
        #expect(try await lane.finish(replacingDecoder: false).output.text == "6")
    }
}
