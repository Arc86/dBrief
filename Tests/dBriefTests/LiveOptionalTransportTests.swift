import Darwin
import Foundation
import Testing
import dBriefWire
@testable import dBrief

private actor OTgate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    func wait() async { entered = true; if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; let held = waiters; waiters = []; for w in held { w.resume() } }
}
private func OTuntil(_ body: () async -> Bool) async -> Bool {
    for _ in 0..<1000 { if await body() { return true }; try? await Task.sleep(for: .milliseconds(2)) }; return false
}

private final class OTdeallocationAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var charge: Int?
    func note(_ value: Int) { lock.withLock { charge = value } }
    var observedCharge: Int? { lock.withLock { charge } }
}

@Suite struct LiveOptionalTransportTests {
    @Test func actualBackingStorageDiesBeforeItsReceiptTicketReturns() throws {
        let audit = OTdeallocationAudit()
        let mailbox = LiveReadMailbox(testingReceiptData: { data, owner in
            let memory = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 16)
            data.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: data.count)
            return Data(bytesNoCopy: memory, count: data.count, deallocator: .custom { [weak owner] pointer, _ in
                audit.note(owner?.residentBytes ?? -1)
                pointer.deallocate()
            })
        })
        #expect(mailbox.offer(Data(repeating: 7, count: 128 * 1024)))
        var receipt = mailbox.take()
        #expect(receipt?.data.count == 16384 && audit.observedCharge == nil)
        receipt = nil
        // An independent backing allocator observes actual storage destruction,
        // not a hook adjacent to the implementation's ticket-return call.
        #expect(audit.observedCharge == 128 * 1024)
        #expect(mailbox.residentBytes == 112 * 1024)
        #expect(mailbox.offer(Data(repeating: 8, count: 16384)))
        #expect(mailbox.residentBytes == 128 * 1024)
        mailbox.discardQueued(); #expect(mailbox.residentBytes == 0)
    }
    @Test(arguments: [1, 2, 3, 511, 512, 8191, 16384])
    func optionalFramesCannotSpendMandatoryFragmentationCapacity(fragment: Int) throws {
        // Two independently made65536-byte frames consume exactly128KiB.
        let frame = FrameCodec.encode(Data(repeating: 0x35, count: 65532)), expected = frame + frame
        // Independent high-bit/header oracle, not the production tag encoder.
        let optional = Data([0x80, 0, 1, 252]) + Data(repeating: 0x42, count: 508)
        let input = frame + optional + frame, mailbox = LiveReadMailbox()
        var mux = LiveOutputDemultiplexer(), observed = Data(), optionalCount = 0
        for start in stride(from: 0, to: input.count, by: fragment) {
            let part = input.subdata(in: start..<min(input.count, start + fragment))
            let filtered = try mux.feed(part) { body in #expect(body == Data(repeating: 0x42, count: 508)); optionalCount += 1 }
            #expect(filtered.count <= part.count + 3 && mux.retainedBytes <= 512)
            #expect(mailbox.offer(filtered)); observed.append(filtered)
        }
        #expect(observed == expected && optionalCount == 1 && mailbox.residentBytes == 128 * 1024)
        #expect(!mailbox.offer(Data([1])))
        var copied = Data()
        while true {
            var receipt = mailbox.take()
            guard receipt != nil else { break }
            #expect(receipt!.data.count <= 16384); copied.append(receipt!.data); receipt = nil
        }
        #expect(copied == expected && mailbox.residentBytes == 0)
    }
    @Test func actualHeldReceiptRetainsChargeAfterCancelAndQueueDiscard() async throws {
        let mailbox = LiveReadMailbox(), gate = OTgate()
        #expect(mailbox.offer(Data(repeating: 7, count: 128 * 1024)))
        let worker = Task {
            var receipt = mailbox.take()
            #expect(receipt?.data.count == 16384)
            await gate.wait() // Deliberately ignores cancellation.
            #expect(mailbox.residentBytes == 16384)
            receipt = nil
        }
        try #require(await OTuntil { await gate.entered })
        worker.cancel(); mailbox.discardQueued()
        #expect(mailbox.residentBytes == 16384 && mailbox.take() == nil)
        #expect(!mailbox.offer(Data([1])))
        await gate.release(); await worker.value
        #expect(mailbox.residentBytes == 0)
    }
    @Test func optionalOnlyFloodAndPartialHeadersNeverOfferAnEmptyMandatoryBlock() throws {
        let optional = Data([0x80, 0, 1, 252]) + Data(repeating: 0x42, count: 508)
        var mux = LiveOutputDemultiplexer()
        for _ in 0..<512 {
            #expect(try mux.feed(optional.prefix(3)).isEmpty)
            #expect(mux.retainedBytes == 3)
            #expect(try mux.feed(Data(optional.dropFirst(3))).isEmpty)
            #expect(mux.retainedBytes == 0)
        }
        let mailbox = LiveReadMailbox(); #expect(mailbox.offer(Data()) && mailbox.take() == nil && mailbox.residentBytes == 0)
    }
    @Test func actualNonblockingReaderTreatsReadinessRaceAsIdleAndKeepsUntaggedBytes() throws {
        let pipe = Pipe(), filter = try LiveOutputReadFilter(pipe.fileHandleForReading), mailbox = LiveReadMailbox()
        #expect(try filter.read(from: pipe.fileHandleForReading, deliver: { _ in Issue.record("idle delivery"); return false }) == .idle)
        let optional = Data([0x80, 0, 0, 1, 0x42])
        try pipe.fileHandleForWriting.write(contentsOf: optional)
        #expect(try filter.read(from: pipe.fileHandleForReading, deliver: { _ in Issue.record("optional delivery"); return false }) == .idle)
        let frame = FrameCodec.encode(Data([1, 2, 3]))
        try pipe.fileHandleForWriting.write(contentsOf: frame)
        #expect(try filter.read(from: pipe.fileHandleForReading, deliver: mailbox.offer) == .delivered)
        var receipt = mailbox.take(); #expect(receipt?.data == frame); receipt = nil
        try pipe.fileHandleForWriting.close()
        #expect(try filter.read(from: pipe.fileHandleForReading, deliver: mailbox.offer) == .eof)
    }
    @Test func actualHelperFloodCannotFillHeldMandatoryIngestOrDecodedEventQueue() async throws {
        let gate = OTgate(), flag = FileManager.default.temporaryDirectory.appendingPathComponent("optional-flood-\(UUID()).flag")
        let identity = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID()), epoch = UUID()
        let scope = LiveLaneScope(identity: identity, source: .system, epochID: epoch)
        let mandatoryReady = LiveSessionEvent.lane(.init(scope: scope, sequence: 0, payload: .ready(generation: UUID(), originSample: 0)))
        let mandatoryBytes = try LiveArtifactEncoding.estimatedBytes(mandatoryReady, limit: 64 * 1024) * 4
        #expect(mandatoryBytes > 4096 && mandatoryBytes < 64 * 1024)
        let c = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
            supportBase: URL(fileURLWithPath: "/private/tmp"), environment: ["STUB_MODE": "live-optional-flood", "STUB_FLAG_1": flag.path],
            role: .live, liveEventLimits: .init(queued: 2, deferred: 2, accountedBytes: mandatoryBytes), boundedIngestDelivery: { await gate.wait() })
        let begin = LiveSessionBegin(identity: identity, configuration: .init(language: .en, modelDirectory: "/fixture"),
            epochs: [.init(id: epoch, source: .system, engineRevision: "fixture", language: "en", meetingOriginNanoseconds: nil)])
        do {
            let stream = try await c.beginLive(begin); await c.armLiveDeadline(.seconds(3))
            try #require(await OTuntil { await gate.entered })
            try #require(await OTuntil { FileManager.default.fileExists(atPath: flag.path) })
            // All262144 optional bytes drained while the actual first mandatory
            // delivery remains held. A decoded malformed body would fail ASR.
            await gate.release()
            var iterator = stream.makeAsyncIterator()
            guard case .lane(let ready) = try await iterator.next(), case .ready = ready.payload else { Issue.record("missing mandatory ready"); await c.shutdownLiveAndWaitForExit(); return }
            #expect(ready.scope.identity == identity)
            let configuration = LiveDiarizationConfiguration(identity: .init(modelFingerprint: String(repeating: "e", count: 64), preset: .low), modelDirectory: "/fixture")
            await #expect(throws: LiveProtocolError.unavailable) {
                _ = try await c.sendLive(.prepareDiarization(scope: ready.scope, ownerID: UUID(), configuration: configuration))
            }
            #expect(try await c.sendLive(.cancel(identity)) == .accepted)
            while try await iterator.next() != nil {}
            await c.shutdownLiveAndWaitForExit()
        } catch { await gate.release(); await c.shutdownLiveAndWaitForExit(); throw error }
        try? FileManager.default.removeItem(at: flag)
    }
}
