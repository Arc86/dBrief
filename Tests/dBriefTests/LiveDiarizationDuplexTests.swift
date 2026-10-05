import CryptoKit
import Darwin
import Foundation
import Testing
@testable import dBriefWire
@testable import dBrief

private actor DXgate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    func hold() async { entered = true; if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let held = waiters; waiters = []; for w in held { w.resume() } }
}
private final class DXaudit: @unchecked Sendable {
    private let lock = NSLock()
    private var hits: [String: Int] = [:]
    private var backingCharge: Int?
    func hit(_ key: String) { lock.withLock { hits[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { lock.withLock { hits[key, default: 0] } }
    func noteCharge(_ n: Int) { lock.withLock { backingCharge = n } }
    var deallocationCharge: Int? { lock.withLock { backingCharge } }
}
private func DXuntil(_ body: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline { if await body() { return true }; try? await Task.sleep(for: .milliseconds(2)) }
    return await body()
}
private struct DXfixture: Sendable {
    let root: URL, assets: LiveDiarizationModelAssets, owner: UUID
    let scope: LiveLaneScope, begin: LiveSessionBegin
    let policy: LiveModelResourcePolicy, lease: LiveResourceLease
    static func make(concurrentChatModels: [String: UInt64] = [:]) async throws -> Self {
        let root = URL(fileURLWithPath: "/private/tmp/diarization-duplex-\(UUID())"), source = root.appendingPathComponent("source"), staging = root.appendingPathComponent("staging")
        let preset = LiveDiarizationPreset.low, model = preset.modelFileName
        var bits = Float(0.375).bitPattern.littleEndian
        let one = withUnsafeBytes(of: &bits) { Data($0) }
        let embedding = (0..<512).reduce(into: Data()) { data, _ in data.append(one) }
        let files = [model + "/metadata.json": Data("{}".utf8), model + "/model.mil": Data("model-free".utf8),
                     model + "/weights/weight.bin": Data([1, 2, 3]), "learnable_sil_emb.bin": embedding,
                     ".fluidaudio-nemotron3-weights": Data(LiveDiarizationIdentity.currentModelRevision.utf8)]
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (rel, data) in files {
            let path = source.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path)
        }
        // Independent descriptor-tree fingerprint oracle, using actual files.
        var hash = SHA256(); hash.update(data: Data("dBrief.DiarizationAssets.v1\0".utf8))
        for rel in (Array(files.keys) + [model, model + "/weights"]).sorted() {
            let bytes = files[rel], path = Data(rel.utf8)
            hash.update(data: Data([bytes == nil ? 0 : 1]))
            var n = UInt32(path.count).littleEndian, size = UInt64(bytes?.count ?? 0).littleEndian
            withUnsafeBytes(of: &n) { hash.update(bufferPointer: $0) }; hash.update(data: path)
            withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }
            if let bytes { hash.update(data: Data(SHA256.hash(data: bytes))) }
        }
        let identity = LiveDiarizationIdentity(modelFingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(), preset: preset, computeUnits: .cpuOnly)
        let assets = try LiveDiarizationModelAssets(sourceDirectory: source, identity: identity, budget: .init(), testingStagingDirectory: staging), owner = UUID()
        try #require(assets.bind(to: owner)); try await assets.prepare(owner: owner)
        let scope = LiveLaneScope(identity: .init(recordingID: UUID(), captureSessionID: UUID()), source: .system, epochID: UUID())
        let begin = LiveSessionBegin(identity: scope.identity, configuration: .init(language: .en, chunkMs: 560, modelDirectory: "/fixture-asr"),
            epochs: [.init(id: scope.epochID, source: .system, engineRevision: "fixture", language: "en", meetingOriginNanoseconds: 1_000_000_000)],
            diarization: .init(ownerID: owner, configuration: assets.configuration))
        let profile = LiveResourceProfile(id: "test", hardware: "fixture", modelRevision: "fixture", chunkMs: 560, sourceCount: 1,
            qualificationID: "model-free-test-only", asrBytes: 100, attributionBytes: 40, headroomBytes: 10,
            concurrentChatModels: concurrentChatModels, backgroundWorkQualified: false, diarization: identity)
        let policy = LiveModelResourcePolicy(profiles: [profile]), token = await policy.measurementToken()
        let request = LiveResourceRequest(profileID: "test", hardware: "fixture", modelRevision: "fixture", chunkMs: 560, sourceCount: 1,
            attributionRequested: true, diarization: identity)
        let lease = try await policy.admitNew(identity: scope.identity, request: request, measurement: .init(availableBytes: 10_000, pressure: .normal), token: token)
        return .init(root: root, assets: assets, owner: owner, scope: scope, begin: begin, policy: policy, lease: lease)
    }
    var admission: LiveModelJobAdmission { .init(policy: policy, measurement: { .init(availableBytes: 10_000, pressure: .normal) }) }
    func start(mode: String = "live-duplex", audit: DXaudit = .init(), mandatoryDelivery: @escaping @Sendable () async -> Void = {},
               optionalDelivery: @escaping @Sendable () async -> Void = {}, afterClaim: (@Sendable () async -> Void)? = nil,
               input: LiveSessionBegin? = nil, confirmResidency: Bool = true, inputWrite: @escaping @Sendable (Bool) -> Void = { _ in }) async throws -> MLHostConnection {
        let c = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"), supportBase: root,
            environment: ["STUB_MODE": mode, "STUB_FLAG_1": root.appendingPathComponent("native-entered").path,
                          "STUB_FLAG_2": root.appendingPathComponent("native-release").path], role: .live,
            liveEventLimits: .init(queued: 8, deferred: 2), boundedIngestDelivery: mandatoryDelivery,
            boundedDiarizationIngestDelivery: optionalDelivery, testingAfterDiarizationClaim: afterClaim, testingLiveInputWrite: inputWrite)
        let stream = try await c.beginLive(input ?? begin)
        Task {
            do { for try await event in stream {
                if case .lane(let lane) = event, case .ready = lane.payload { audit.hit("ready") }
                if case .lane(let lane) = event, case .committed = lane.payload { audit.hit("commit") }
                if case .finished = event { audit.hit("finished") }
            } } catch { audit.hit("error") }
        }
        try #require(await DXuntil { audit.count("ready") == 1 })
        // Model-free helper's actual ready arrival; this is no physical residency qualification.
        if confirmResidency { await policy.confirmResident(lease) }
        return c
    }
    func open(_ c: MLHostConnection, admission: LiveModelJobAdmission? = nil) async throws -> AsyncThrowingStream<LiveDiarizationEvent, Error> {
        try await c.openDiarization(assets: assets, ownerID: owner, lease: lease, admission: admission ?? self.admission)
    }
    func control(_ payload: LiveDiarizationControl.Payload) -> LiveDiarizationControl { .init(identity: scope.identity, ownerID: owner, payload: payload) }
    var staged: Bool { FileManager.default.fileExists(atPath: assets.configuration.modelDirectory) }
    func finish(_ c: MLHostConnection) async {
        await c.shutdownLiveAndWaitForExit(); await assets.retire(owner: owner)?.value
        await policy.release(lease); try? FileManager.default.removeItem(at: root)
    }
}

@Suite struct LiveDiarizationDuplexTests {
    @Test func independentCompactControlBytesAndActualOuterAtomicBoundary() throws {
        let recording = try #require(UUID(uuidString: "01020304-0506-0708-090a-0b0c0d0e0f10"))
        let capture = try #require(UUID(uuidString: "11121314-1516-1718-191a-1b1c1d1e1f20"))
        let owner = try #require(UUID(uuidString: "21222324-2526-2728-292a-2b2c2d2e2f30"))
        let context = try #require(UUID(uuidString: "31323334-3536-3738-393a-3b3c3d3e3f40"))
        let identity = LiveSessionIdentity(recordingID: recording, captureSessionID: capture)
        let payloads: [LiveDiarizationControl.Payload] = [.prepare(epochID: context), .acknowledge(contextID: context),
            .acknowledgePosterior(contextID: context, sequence: UInt64.max - 1), .retire]
        let pipe = Pipe(), limit = fpathconf(pipe.fileHandleForWriting.fileDescriptor, _PC_PIPE_BUF)
        #expect(limit == 512)
        for (kind, payload) in payloads.enumerated() {
            var raw = Data([1, UInt8(kind)] + Array(1...48).map(UInt8.init))
            if kind < 3 { raw.append(contentsOf: Array(49...64).map(UInt8.init)) }
            if kind == 2 { raw.append(contentsOf: [0xfe] + [UInt8](repeating: 0xff, count: 7)) }
            let control = LiveDiarizationControl(identity: identity, ownerID: owner, payload: payload)
            let decoded = try JSONDecoder().decode(LiveDiarizationControl.self, from: JSONEncoder().encode(raw))
            #expect(decoded == control)
            #expect(try JSONDecoder().decode(Data.self, from: JSONEncoder().encode(control)) == raw)
            let envelope = RequestEnvelope(id: owner, request: .live(.diarizationControl(control)))
            let frame = FrameCodec.encode(try JSONEncoder().encode(envelope))
            #expect(frame.count <= limit && frame.first! & 0x80 == 0)
            #expect(LiveSessionRequest.diarizationControl(control).isOptionalDiarizationControl)
            for n in 0..<raw.count {
                #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(LiveDiarizationControl.self, from: JSONEncoder().encode(Data(raw.prefix(n)))) }
            }
            for bad in [Data([2]) + raw.dropFirst(), Data([1, 4]) + raw.dropFirst(2), raw + Data([0])] {
                #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(LiveDiarizationControl.self, from: JSONEncoder().encode(bad)) }
            }
            if kind == 2 {
                var overflow = raw; overflow.replaceSubrange((raw.count - 8)..<raw.count, with: [UInt8](repeating: 0xff, count: 8))
                #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(LiveDiarizationControl.self, from: JSONEncoder().encode(overflow)) }
            }
        }
    }

    @Test func actualInputWriterRefusesFullPipeAndBusyMandatoryWriteWithoutChangingBytes() async throws {
        let pipe = Pipe(), fd = pipe.fileHandleForWriting.fileDescriptor, audit = DXaudit()
        let w = LivePipeWriter(handle: pipe.fileHandleForWriting, failed: { audit.hit("failed") })
        let frame = FrameCodec.encode(Data([1, 2, 3]))
        #expect(w.tryWriteOptional(frame))
        var reader = [UInt8](repeating: 0, count: frame.count)
        #expect(Darwin.read(pipe.fileHandleForReading.fileDescriptor, &reader, reader.count) == frame.count && Data(reader) == frame)
        let flags = fcntl(fd, F_GETFL); #expect(fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0)
        let filler = [UInt8](repeating: 0x53, count: 512)
        var filled = 0
        while true {
            let n = filler.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }; filled += n
        }
        #expect(errno == EAGAIN && filled > 0); #expect(fcntl(fd, F_SETFL, flags) == 0)
        let start = ContinuousClock.now
        #expect(!w.tryWriteOptional(frame) && ContinuousClock.now - start < .milliseconds(100))
        #expect(fcntl(fd, F_GETFL) == flags)
        // A real blocking mandatory write is now held by the full kernel FIFO.
        let mandatory = FrameCodec.encode(Data(repeating: 0x64, count: 16_380))
        #expect(w.enqueue(mandatory))
        try? await Task.sleep(for: .milliseconds(20))
        let held = ContinuousClock.now
        #expect(!w.tryWriteOptional(frame) && ContinuousClock.now - held < .milliseconds(100))
        let total = filled + mandatory.count
        var actual = Data()
        while actual.count < total {
            var bytes = [UInt8](repeating: 0, count: min(16_384, total - actual.count))
            let n = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            try #require(n > 0); actual.append(contentsOf: bytes.prefix(n))
        }
        #expect(actual == Data(repeating: 0x53, count: filled) + mandatory)
        #expect(audit.count("failed") == 0)
        #expect(!w.tryWriteOptional(Data(repeating: 7, count: 513)))
        w.retire()
        let file = URL(fileURLWithPath: "/private/tmp/optional-writer-\(UUID())")
        try Data().write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file), unsupported = LivePipeWriter(handle: handle, failed: {})
        #expect(!unsupported.tryWriteOptional(frame)); unsupported.retire()
    }

    @Test func independentOptionalMailboxKeepsActualBackingAndFrameTicketsWhileHeld() async throws {
        let audit = DXaudit(), gate = DXgate()
        let mailbox = LiveOptionalReadMailbox(testingReceiptData: { bytes, owner in
            let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 16)
            bytes.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: bytes.count)
            return Data(bytesNoCopy: memory, count: bytes.count, deallocator: .custom { [weak owner] pointer, _ in
                audit.noteCharge(owner?.residentBytes ?? -1); pointer.deallocate()
            })
        })
        #expect(mailbox.offer(Data([1])) == .ignored); #expect(mailbox.activate())
        for _ in 0..<8 { #expect(mailbox.offer(Data(repeating: 7, count: 508)) == .accepted) }
        #expect(mailbox.residentBytes == 4064 && mailbox.residentFrames == 8)
        let task = Task {
            var receipt = mailbox.take(); #expect(receipt?.data.count == 508)
            await gate.hold()
            #expect(mailbox.residentBytes == 508 && mailbox.residentFrames == 1)
            receipt = nil
        }
        try #require(await DXuntil { await gate.entered })
        #expect(mailbox.offer(Data([1])) == .overflow)
        task.cancel(); mailbox.discardQueued()
        #expect(mailbox.residentBytes == 508 && mailbox.take() == nil && audit.deallocationCharge == nil)
        await gate.release(); await task.value
        #expect(audit.deallocationCharge == 508 && mailbox.residentBytes == 0 && mailbox.residentFrames == 0)
        #expect(!mailbox.activate() && mailbox.offer(Data([1])) == .ignored)
    }

    @Test func actualParentOwnedRoundtripAndExactNativeReceiptJoinsFilesystemBeforeRefund() async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), c = try await f.start(audit: audit)
        do {
            let optional = try await f.open(c); var iterator = optional.makeAsyncIterator()
            try FileManager.default.removeItem(at: f.root.appendingPathComponent("source"))
            #expect(try await c.sendDiarizationControl(f.control(.prepare(epochID: f.scope.epochID))) == .accepted)
            guard case .preparing = try await iterator.next()?.payload else { throw LiveProtocolError.invalidPacket }
            guard case .ready(let origin, let context) = try await iterator.next()?.payload else { throw LiveProtocolError.invalidPacket }
            #expect(origin == 0 && f.staged); #expect(await f.policy.reservedBytes == 140)
            #expect(try await c.sendDiarizationControl(f.control(.acknowledge(contextID: context))) == .accepted)
            guard case .posterior(let received, let rows) = try await iterator.next()?.payload else { throw LiveProtocolError.invalidPacket }
            #expect(received == context && rows.count == 2)
            #expect(try rows[0].activityValues() == [Float](repeating: 0.7, count: 8))
            #expect(try await c.sendDiarizationControl(f.control(.acknowledgePosterior(contextID: context, sequence: 2))) == .accepted)
            #expect(try await c.sendDiarizationControl(f.control(.retire)) == .accepted)
            guard case .retired(let retired, _, _) = try await iterator.next()?.payload else { throw LiveProtocolError.invalidPacket }
            #expect(retired == context)
            try #require(await DXuntil { await f.policy.reservedBytes == 100 })
            #expect(!f.staged); #expect(try await iterator.next() == nil)
            // Optional proof never returns the mandatory capture lease.
            #expect(await f.policy.validateActiveLease(f.lease))
            #expect(try await c.sendLive(.cancel(f.scope.identity)) == .accepted)
            try #require(await DXuntil { audit.count("finished") == 1 }); #expect(audit.count("error") == 0)
            await f.finish(c)
        } catch { await f.finish(c); throw error }
    }

    @Test func heldOptionalDeliveryAndMalformedFloodNeverBlockASROrRefundBeforeChildExit() async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), gate = DXgate(), c = try await f.start(mode: "live-duplex-malformed", audit: audit, optionalDelivery: { await gate.hold() })
        do {
            let optional = try await f.open(c)
            let prepare = Task { try await c.sendDiarizationControl(f.control(.prepare(epochID: f.scope.epochID)), deadline: .milliseconds(100)) }
            try #require(await DXuntil { await gate.entered })
            #expect(await f.policy.reservedBytes == 140 && f.staged)
            // Mandatory cancel/reply/terminal flow while actual optional ingest is held.
            #expect(try await c.sendLive(.cancel(f.scope.identity)) == .accepted)
            try #require(await DXuntil { audit.count("finished") == 1 && audit.count("error") == 0 })
            await gate.release()
            _ = await prepare.result
            var iterator = optional.makeAsyncIterator()
            do { while try await iterator.next() != nil {} } catch {}
            await c.shutdownLiveAndWaitForExit()
            #expect(await f.policy.reservedBytes == 100 && !f.staged)
            await f.finish(c)
        } catch { await gate.release(); await f.finish(c); throw error }
    }

    @Test func cancelledLateClaimRemainsJoinedAcrossActualShutdownAndCannotDispatch() async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), gate = DXgate(), c = try await f.start(audit: audit, afterClaim: { await gate.hold() })
        do {
            let opening = Task { try await f.open(c) }
            try #require(await DXuntil { await gate.entered })
            opening.cancel()
            let shutdown = Task { await c.shutdownLiveAndWaitForExit(); audit.hit("shutdown-returned") }
            try? await Task.sleep(for: .milliseconds(30))
            #expect(audit.count("shutdown-returned") == 0 && f.staged); #expect(await f.policy.reservedBytes == 140)
            #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("native-entered").path))
            await gate.release()
            if case .success = await opening.result { Issue.record("canceled admission reopened") }
            await shutdown.value
            #expect(!f.staged); #expect(await f.policy.reservedBytes == 100)
            await f.finish(c)
        } catch { await gate.release(); await f.finish(c); throw error }
    }

    @Test func borrowedAndRetiredLeaseCannotDispatchOrDeleteTheOriginalOwnedRoot() async throws {
        let f = try await DXfixture.make(), c = try await f.start()
        var second: MLHostConnection?
        do {
            let original = try await f.open(c)
            second = try await f.start()
            await #expect(throws: (any Error).self) { _ = try await f.open(second!) }
            await second?.shutdownLiveAndWaitForExit(); second = nil
            #expect(f.staged); #expect(await f.policy.reservedBytes == 140)
            // A legacy lease-only confirmation cannot refund a claimed native owner.
            await f.policy.confirmAttributionRetired(f.lease)
            #expect(await f.policy.reservedBytes == 140)
            #expect(try await c.sendDiarizationControl(f.control(.prepare(epochID: f.scope.epochID))) == .accepted)
            var iterator = original.makeAsyncIterator(); _ = try await iterator.next()
            guard case .ready(_, let context) = try await iterator.next()?.payload else { throw LiveProtocolError.invalidPacket }
            #expect(try await c.sendDiarizationControl(f.control(.retire)) == .accepted)
            guard case .retired(let got, _, _) = try await iterator.next()?.payload else { throw LiveProtocolError.invalidPacket }
            #expect(got == context)
            try #require(await DXuntil { await f.policy.reservedBytes == 100 })
            await #expect(throws: (any Error).self) { _ = try await f.open(c) }
            #expect(await f.policy.validateActiveLease(f.lease))
            await f.finish(c)
        } catch { await second?.shutdownLiveAndWaitForExit(); await f.finish(c); throw error }
    }

    @Test(arguments: ["owner", "fingerprint", "preset", "compute", "lease", "policy", "nil-frozen", "root", "unresident", "retired-fresh", "pressure"])
    func actualAdmissionRejectionsLeaveASRAndExistingAssetAuthorityIntact(mode: String) async throws {
        let f = try await DXfixture.make(), audit = DXaudit()
        let plain = LiveSessionBegin(identity: f.begin.identity, configuration: f.begin.configuration, epochs: f.begin.epochs)
        let c = try await f.start(audit: audit, input: mode == "nil-frozen" ? plain : nil, confirmResidency: mode != "unresident")
        let moved = URL(fileURLWithPath: f.assets.configuration.modelDirectory + "-original")
        var rootMoved = false
        do {
            var requestLease = f.lease, requestAdmission = f.admission
            if ["fingerprint", "preset", "compute"].contains(mode) {
                let original = f.assets.configuration.identity
                let identity = LiveDiarizationIdentity(modelFingerprint: mode == "fingerprint" ? String(repeating: "a", count: 64) : original.modelFingerprint,
                    preset: mode == "preset" ? .fast : original.preset, computeUnits: mode == "compute" ? .cpuAndNeuralEngine : original.computeUnits)
                let request = LiveResourceRequest(profileID: "test", hardware: "fixture", modelRevision: "fixture", chunkMs: 560,
                    sourceCount: 1, attributionRequested: true, diarization: identity)
                requestLease = .init(id: f.lease.id, identity: f.lease.identity, request: request, attributionEnabled: true, reservedBytes: 140)
            }
            if mode == "lease" { requestLease = .init(id: UUID(), identity: f.lease.identity, request: f.lease.request, attributionEnabled: true, reservedBytes: 140) }
            if mode == "policy" { requestAdmission = .init(policy: .init(), measurement: { .init(availableBytes: 10_000, pressure: .normal) }) }
            if mode == "pressure" { requestAdmission = .init(policy: f.policy, measurement: { .init(availableBytes: 10_000, pressure: .warning) }) }
            if mode == "retired-fresh" { await f.policy.confirmAttributionRetired(f.lease) }
            if mode == "root" {
                try FileManager.default.moveItem(at: URL(fileURLWithPath: f.assets.configuration.modelDirectory), to: moved)
                rootMoved = true
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: f.assets.configuration.modelDirectory), withIntermediateDirectories: false)
            }
            await #expect(throws: (any Error).self) {
                _ = try await c.openDiarization(assets: f.assets, ownerID: mode == "owner" ? UUID() : f.owner,
                    lease: requestLease, admission: requestAdmission)
            }
            if rootMoved {
                try FileManager.default.removeItem(at: URL(fileURLWithPath: f.assets.configuration.modelDirectory))
                try FileManager.default.moveItem(at: moved, to: URL(fileURLWithPath: f.assets.configuration.modelDirectory)); rootMoved = false
            }
            #expect(f.staged)
            #expect(await f.policy.reservedBytes == (mode == "retired-fresh" ? 100 : 140))
            #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("native-entered").path))
            #expect(try await c.sendLive(.cancel(f.scope.identity)) == .accepted)
            try #require(await DXuntil { audit.count("finished") == 1 }); #expect(audit.count("error") == 0)
            await f.finish(c)
        } catch {
            if rootMoved {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: f.assets.configuration.modelDirectory))
                try? FileManager.default.moveItem(at: moved, to: URL(fileURLWithPath: f.assets.configuration.modelDirectory))
            }
            await f.finish(c); throw error
        }
    }

    @Test(arguments: [false, true])
    func actualOptionalCancellationAndDeadlineDoNotTakeMandatoryRequestCapacity(cancel: Bool) async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), c = try await f.start(mode: "live-duplex-no-reply", audit: audit)
        do {
            let optional = try await f.open(c); var iterator = optional.makeAsyncIterator()
            let command = Task { try await c.sendDiarizationControl(f.control(.prepare(epochID: f.scope.epochID)), deadline: .milliseconds(100)) }
            _ = try await iterator.next(); _ = try await iterator.next()
            #expect(await c.livePendingCount == 0)
            if cancel { command.cancel() }
            switch await command.result {
            case .success: Issue.record("missing optional reply was accepted")
            case .failure(let error):
                if cancel { #expect(error is CancellationError) } else { #expect(error as? MLHostError == .liveDeadline) }
            }
            #expect(await c.diarizationPendingCount == 0)
            #expect(f.staged); #expect(await f.policy.reservedBytes == 140)
            #expect(try await c.sendLive(.packet(try .init(scope: f.scope, sequence: 0, startSample: 0, samples: [Float](repeating: 1, count: 160)))) == .accepted)
            #expect(try await c.sendLive(.barrier(.init(scope: f.scope, nextPacketSequence: 1, sampleEnd: 160, kind: .utterance))) == .accepted)
            try #require(await DXuntil { audit.count("commit") == 1 }); #expect(audit.count("error") == 0)
            await f.finish(c)
        } catch { await f.finish(c); throw error }
    }

    @Test func fourIndependentPendingControlsBoundCapacityWhileASRStillCommits() async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), c = try await f.start(mode: "live-duplex-no-reply", audit: audit)
        var commands: [Task<LiveSessionReply, Error>] = []
        do {
            let optional = try await f.open(c); var iterator = optional.makeAsyncIterator()
            commands.append(Task { try await c.sendDiarizationControl(f.control(.prepare(epochID: f.scope.epochID)), deadline: .seconds(1)) })
            _ = try await iterator.next(); _ = try await iterator.next()
            for _ in 0..<3 { commands.append(Task { try await c.sendDiarizationControl(f.control(.retire), deadline: .seconds(1)) }) }
            try #require(await DXuntil { await c.diarizationPendingCount == 4 })
            #expect(await c.livePendingCount == 0)
            await #expect(throws: LiveProtocolError.outputLimit) { _ = try await c.sendDiarizationControl(f.control(.retire)) }
            for command in commands { if case .success = await command.result { Issue.record("unanswered optional control succeeded") } }
            #expect(await c.diarizationPendingCount == 0)
            #expect(f.staged); #expect(await f.policy.reservedBytes == 140)
            #expect(try await c.sendLive(.packet(try .init(scope: f.scope, sequence: 0, startSample: 0, samples: [Float](repeating: 1, count: 160)))) == .accepted)
            #expect(try await c.sendLive(.barrier(.init(scope: f.scope, nextPacketSequence: 1, sampleEnd: 160, kind: .utterance))) == .accepted)
            try #require(await DXuntil { audit.count("commit") == 1 }); #expect(audit.count("error") == 0)
            await f.finish(c)
        } catch { for command in commands { command.cancel() }; await f.finish(c); for command in commands { _ = await command.result }; throw error }
    }

    @Test(arguments: [false, true])
    func optionalRetiredReceiptCannotOutrunActualReplacementAcceptance(rejected: Bool) async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), gate = DXgate()
        let c = try await f.start(mode: rejected ? "live-duplex-reject-replacement" : "live-duplex-retire-on-replacement", audit: audit,
            mandatoryDelivery: { if audit.count("hold-mandatory") > 0 { await gate.hold() } })
        do {
            let optional = try await f.open(c); var iterator = optional.makeAsyncIterator()
            #expect(try await c.sendDiarizationControl(f.control(.prepare(epochID: f.scope.epochID))) == .accepted)
            _ = try await iterator.next(); _ = try await iterator.next()
            let epoch = LiveEpoch(id: UUID(), source: .system, engineRevision: "fixture", language: "en", meetingOriginNanoseconds: 2_000_000_000)
            audit.hit("hold-mandatory")
            let replacing = Task { try await c.sendLive(.replaceEpoch(identity: f.scope.identity, oldEpochID: f.scope.epochID, epoch: epoch)) }
            try #require(await DXuntil { await gate.entered })
            try #require(await DXuntil { await c.diarizationAwaitingEpochCount == 1 })
            #expect(await c.diarizationRawResidentBytes > 0)
            #expect(f.staged); #expect(await f.policy.reservedBytes == 140)
            await gate.release()
            #expect(try await replacing.value == (rejected ? .rejected(.unavailable) : .accepted))
            if rejected {
                await #expect(throws: LiveProtocolError.staleScope) { _ = try await iterator.next() }
                #expect(f.staged); #expect(await f.policy.reservedBytes == 140)
                #expect(try await c.sendLive(.packet(try .init(scope: f.scope, sequence: 0, startSample: 0, samples: [Float](repeating: 1, count: 160)))) == .accepted)
            } else {
                let event = try #require(try await iterator.next())
                guard case .retired = event.payload else { throw LiveProtocolError.invalidPacket }
                #expect(event.scope.epochID == epoch.id)
                try #require(await DXuntil { await f.policy.reservedBytes == 100 }); #expect(!f.staged)
                try #require(await DXuntil { audit.count("ready") == 2 })
            }
            #expect(audit.count("error") == 0)
            await f.finish(c)
        } catch { await gate.release(); await f.finish(c); throw error }
    }

    @Test(arguments: [false, true])
    func everyFailedChildLaunchReturnsItsActualOptionalReaderBeforeRetryCleanup(nonexecutable: Bool) async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), binary = f.root.appendingPathComponent("invalid-helper")
        if nonexecutable { try Data("not executable".utf8).write(to: binary); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binary.path) }
        let c = MLHostConnection(binaryURL: binary, supportBase: f.root, role: .live,
            testingDiarizationReaderLifetime: { audit.hit($0 ? "reader-entered" : "reader-returned") })
        do {
            for _ in 0..<8 {
                await #expect(throws: MLHostError.helperUnavailable) { _ = try await c.beginLive(f.begin) }
            }
            try #require(await DXuntil { audit.count("reader-entered") == 8 && audit.count("reader-returned") == 8 })
            // Observe actual returns before shutdown can mask a latest-only cleanup.
            #expect(audit.count("reader-entered") == audit.count("reader-returned"))
            await f.finish(c)
        } catch { await f.finish(c); throw error }
    }

    @Test(arguments: [false, true])
    func optionalOpenAfterAcceptedOrRejectedReplacementPreservesExactCurrentScope(rejected: Bool) async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), c = try await f.start(mode: rejected ? "live-duplex-reject-before-open" : "live-duplex", audit: audit)
        let replacement = LiveEpoch(id: UUID(), source: .system, engineRevision: "fixture", language: "en", meetingOriginNanoseconds: nil)
        do {
            #expect(try await c.sendLive(.barrier(.init(scope: f.scope, nextPacketSequence: 0, sampleEnd: 0, kind: .pause))) == .accepted)
            #expect(try await c.sendLive(.replaceEpoch(identity: f.scope.identity, oldEpochID: f.scope.epochID, epoch: replacement)) == (rejected ? .rejected(.unavailable) : .accepted))
            let optional = try await f.open(c); var iterator = optional.makeAsyncIterator()
            let current = rejected ? f.scope.epochID : replacement.id
            #expect(try await c.sendDiarizationControl(f.control(.prepare(epochID: current))) == .accepted)
            let preparing = try #require(try await iterator.next()); #expect(preparing.scope.epochID == current)
            let ready = try #require(try await iterator.next()); #expect(ready.scope.epochID == current)
            #expect(try await c.sendDiarizationControl(f.control(.retire)) == .accepted)
            let retired = try #require(try await iterator.next()); #expect(retired.scope.epochID == current)
            try #require(await DXuntil { await f.policy.reservedBytes == 100 }); #expect(!f.staged)
            #expect(try await c.sendLive(.cancel(f.scope.identity)) == .accepted)
            try #require(await DXuntil { audit.count("finished") == 1 }); #expect(audit.count("error") == 0)
            await f.finish(c)
        } catch { await f.finish(c); throw error }
    }

    @Test func obsoletePrepareCannotConsumeSoleDispatchAfterPreOpenReplacement() async throws {
        let f = try await DXfixture.make(), c = try await f.start()
        let replacement = LiveEpoch(id: UUID(), source: .system, engineRevision: "fixture", language: "en", meetingOriginNanoseconds: nil)
        do {
            #expect(try await c.sendLive(.replaceEpoch(identity: f.scope.identity, oldEpochID: f.scope.epochID, epoch: replacement)) == .accepted)
            let optional = try await f.open(c); var iterator = optional.makeAsyncIterator()
            await #expect(throws: LiveProtocolError.staleScope) { _ = try await c.sendDiarizationControl(f.control(.prepare(epochID: f.scope.epochID))) }
            #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("native-entered").path))
            #expect(try await c.sendDiarizationControl(f.control(.prepare(epochID: replacement.id))) == .accepted)
            _ = try await iterator.next(); _ = try await iterator.next()
            #expect(try await c.sendDiarizationControl(f.control(.retire)) == .accepted)
            await f.finish(c)
        } catch { await f.finish(c); throw error }
    }

    @Test func heldReplacementBeforeOptionalOpenCannotPromoteTentativeAuthority() async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), gate = DXgate()
        let c = try await f.start(audit: audit, mandatoryDelivery: { if audit.count("hold-mandatory") > 0 { await gate.hold() } })
        let replacement = LiveEpoch(id: UUID(), source: .system, engineRevision: "fixture", language: "en", meetingOriginNanoseconds: nil)
        var command: Task<LiveSessionReply, Error>?
        do {
            audit.hit("hold-mandatory")
            command = Task { try await c.sendLive(.replaceEpoch(identity: f.scope.identity, oldEpochID: f.scope.epochID, epoch: replacement)) }
            try #require(await DXuntil { await gate.entered })
            let optional = try await f.open(c); var iterator = optional.makeAsyncIterator()
            await #expect(throws: LiveProtocolError.staleScope) { _ = try await c.sendDiarizationControl(f.control(.prepare(epochID: replacement.id))) }
            #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("native-entered").path))
            await gate.release(); #expect(try await command?.value == .accepted)
            #expect(try await c.sendDiarizationControl(f.control(.prepare(epochID: replacement.id))) == .accepted)
            let preparing = try #require(try await iterator.next()); #expect(preparing.scope.epochID == replacement.id)
            _ = try await iterator.next()
            #expect(try await c.sendDiarizationControl(f.control(.retire)) == .accepted)
            await f.finish(c)
        } catch { await gate.release(); await f.finish(c); _ = await command?.result; throw error }
    }

    @Test func preOpenEpochCapacityFailureIsStickyButDoesNotRejectASRReplacement() async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), c = try await f.start(audit: audit)
        var current = f.scope.epochID
        do {
            for _ in 0..<64 {
                let epoch = LiveEpoch(id: UUID(), source: .system, engineRevision: "fixture", language: "en", meetingOriginNanoseconds: nil)
                #expect(try await c.sendLive(.replaceEpoch(identity: f.scope.identity, oldEpochID: current, epoch: epoch)) == .accepted)
                current = epoch.id
            }
            await #expect(throws: LiveProtocolError.unavailable) { _ = try await f.open(c) }
            #expect(f.staged); #expect(await f.policy.reservedBytes == 140)
            let scope = LiveLaneScope(identity: f.scope.identity, source: .system, epochID: current)
            #expect(try await c.sendLive(.packet(try .init(scope: scope, sequence: 0, startSample: 0, samples: [Float](repeating: 1, count: 160)))) == .accepted)
            #expect(try await c.sendLive(.barrier(.init(scope: scope, nextPacketSequence: 1, sampleEnd: 160, kind: .utterance))) == .accepted)
            try #require(await DXuntil { audit.count("commit") == 1 }); #expect(audit.count("error") == 0)
            await f.finish(c)
        } catch { await f.finish(c); throw error }
    }

    @Test func cancellationIgnoringMeasurementRemainsJoinedBeforeAnyPolicyClaim() async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), gate = DXgate(), c = try await f.start(audit: audit)
        let admission = LiveModelJobAdmission(policy: f.policy, measurement: { await gate.hold(); return .init(availableBytes: 10_000, pressure: .normal) })
        do {
            let opening = Task { try await f.open(c, admission: admission) }
            try #require(await DXuntil { await gate.entered })
            opening.cancel()
            let shutdown = Task { await c.shutdownLiveAndWaitForExit(); audit.hit("shutdown-returned") }
            try? await Task.sleep(for: .milliseconds(30))
            #expect(audit.count("shutdown-returned") == 0 && f.staged); #expect(await f.policy.reservedBytes == 140)
            await gate.release()
            if case .success = await opening.result { Issue.record("cancelled measurement admitted optional work") }
            await shutdown.value
            // No transport claim existed. The original caller still owns both
            // this copied root and the capture receipt, through actual return.
            #expect(f.staged); #expect(await f.policy.reservedBytes == 140)
            #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("native-entered").path))
            await f.finish(c)
        } catch { await gate.release(); await f.finish(c); throw error }
    }

    @Test func namedRootReplacementAfterClaimFailsBeforeDispatchAndPreservesForeignEntry() async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), gate = DXgate(), c = try await f.start(audit: audit, afterClaim: { await gate.hold() })
        let path = URL(fileURLWithPath: f.assets.configuration.modelDirectory), moved = URL(fileURLWithPath: f.assets.configuration.modelDirectory + "-original")
        var substituted = false
        do {
            let opening = Task { try await f.open(c) }
            try #require(await DXuntil { await gate.entered })
            try FileManager.default.moveItem(at: path, to: moved); substituted = true
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            let marker = path.appendingPathComponent("foreign-marker"), bytes = Data("preserve foreign entry".utf8)
            try bytes.write(to: marker); await gate.release()
            switch await opening.result {
            case .success: Issue.record("substituted post-claim path admitted")
            case .failure(let error): #expect(error as? LiveASRAssetError == .invalidAsset)
            }
            #expect(try Data(contentsOf: marker) == bytes); #expect(FileManager.default.fileExists(atPath: moved.path))
            #expect(await f.policy.reservedBytes == 140)
            #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("native-entered").path))
            #expect(try await c.sendLive(.cancel(f.scope.identity)) == .accepted)
            try #require(await DXuntil { audit.count("finished") == 1 }); #expect(audit.count("error") == 0)
            // Restore only the test's own exact fixture before normal cleanup.
            #expect(try Data(contentsOf: marker) == bytes)
            try FileManager.default.removeItem(at: path); try FileManager.default.moveItem(at: moved, to: path); substituted = false
            await f.finish(c)
        } catch {
            await gate.release()
            if substituted { try? FileManager.default.removeItem(at: path); try? FileManager.default.moveItem(at: moved, to: path) }
            await f.finish(c); throw error
        }
    }

    @Test func actualParentRefusesOptionalInputAndStopsWhileChildPipeWriteIsHeld() async throws {
        let f = try await DXfixture.make(), audit = DXaudit()
        let c = try await f.start(mode: "live-duplex-input-stall", audit: audit,
            inputWrite: { audit.hit($0 ? "write-entered" : "write-returned") })
        var commands: [Task<LiveSessionReply, Error>] = []
        do {
            try #require(await DXuntil { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("native-release").path) })
            _ = try await f.open(c)
            for sequence in 0..<24 {
                let packet = try LiveAudioPacket(scope: f.scope, sequence: UInt64(sequence), startSample: Int64(sequence * 3200), samples: [Float](repeating: 1, count: 3200))
                commands.append(Task { try await c.sendLive(.packet(packet)) })
            }
            try #require(await DXuntil { await c.livePendingCount == 24 && audit.count("write-entered") > audit.count("write-returned") })
            await #expect(throws: LiveProtocolError.unavailable) { _ = try await c.sendDiarizationControl(f.control(.prepare(epochID: f.scope.epochID))) }
            #expect(await c.diarizationPendingCount == 0); #expect(await c.livePendingCount == 24)
            #expect(f.staged); #expect(await f.policy.reservedBytes == 140)
            let shutdown = Task { await c.shutdownLiveAndWaitForExit(); audit.hit("shutdown-returned") }
            try #require(await DXuntil { audit.count("shutdown-returned") == 1 }); await shutdown.value
            for command in commands { if case .success = await command.result { Issue.record("stalled child acknowledged input") } }
            #expect(audit.count("write-entered") == audit.count("write-returned"))
            #expect(!f.staged); #expect(await f.policy.reservedBytes == 100)
            await f.finish(c)
        } catch { for command in commands { command.cancel() }; await f.finish(c); for command in commands { _ = await command.result }; throw error }
    }

    @Test func lateOptionalClaimAccountsForAlreadyReservedUnallocatedChat() async throws {
        let f = try await DXfixture.make(concurrentChatModels: ["fixture-chat": 200]), audit = DXaudit(), c = try await f.start(audit: audit)
        let job = try #require(await f.policy.reserveJob(owner: UUID(), job: .localChat(model: "fixture-chat"),
            measurement: .init(availableBytes: 10_000, pressure: .normal)))
        do {
            // Current telemetry excludes this unallocated200-byte chat receipt.
            // Optional40 + headroom10 fits100; both pending owners require250.
            let admission = LiveModelJobAdmission(policy: f.policy, measurement: { .init(availableBytes: 100, pressure: .normal) })
            await #expect(throws: LiveResourceRejection.insufficientMemory) { _ = try await f.open(c, admission: admission) }
            #expect(f.staged); #expect(await f.policy.reservedBytes == 140)
            #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("native-entered").path))
            #expect(try await c.sendLive(.cancel(f.scope.identity)) == .accepted)
            try #require(await DXuntil { audit.count("finished") == 1 }); #expect(audit.count("error") == 0)
            await f.finish(c); await f.policy.releaseJob(job)
        } catch { await f.finish(c); await f.policy.releaseJob(job); throw error }
    }

    @Test func acceptedRetirementKeepsNativeAssetsAndChargeUntilActualReceipt() async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), c = try await f.start(mode: "live-duplex-held-retirement", audit: audit)
        do {
            let optional = try await f.open(c); var iterator = optional.makeAsyncIterator()
            #expect(try await c.sendDiarizationControl(f.control(.prepare(epochID: f.scope.epochID))) == .accepted)
            _ = try await iterator.next()
            guard case .ready(_, let context) = try await iterator.next()?.payload else { throw LiveProtocolError.invalidPacket }
            #expect(try await c.sendDiarizationControl(f.control(.retire)) == .accepted)
            #expect(f.staged); #expect(await f.policy.reservedBytes == 140)
            #expect(try await c.sendLive(.packet(try .init(scope: f.scope, sequence: 0, startSample: 0, samples: [Float](repeating: 1, count: 160)))) == .accepted)
            #expect(try await c.sendLive(.barrier(.init(scope: f.scope, nextPacketSequence: 1, sampleEnd: 160, kind: .utterance))) == .accepted)
            try #require(await DXuntil { audit.count("commit") == 1 }); #expect(audit.count("error") == 0)
            #expect(f.staged); #expect(await f.policy.reservedBytes == 140)
            try Data().write(to: f.root.appendingPathComponent("native-release"))
            #expect(try await c.sendDiarizationControl(f.control(.retire)) == .accepted)
            guard case .retired(let received, _, _) = try await iterator.next()?.payload else { throw LiveProtocolError.invalidPacket }
            #expect(received == context); try #require(await DXuntil { await f.policy.reservedBytes == 100 })
            #expect(!f.staged); #expect(await f.policy.validateActiveLease(f.lease))
            await f.finish(c)
        } catch { await f.finish(c); throw error }
    }

    @Test(arguments: ["live-duplex-foreign", "live-duplex-bad-body", "live-duplex-foreign-epoch", "live-duplex-bad-sequence"])
    func invalidOptionalEvidenceCannotQualifyRetirementOrStopASR(mode: String) async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), c = try await f.start(mode: mode, audit: audit)
        do {
            let optional = try await f.open(c); var iterator = optional.makeAsyncIterator()
            #expect(try await c.sendDiarizationControl(f.control(.prepare(epochID: f.scope.epochID))) == .accepted)
            do { while try await iterator.next() != nil {}; Issue.record("invalid optional evidence remained publishable") }
            catch { #expect(error as? LiveProtocolError == (mode == "live-duplex-foreign-epoch" ? .staleScope : .invalidPacket)) }
            #expect(try await c.sendDiarizationControl(f.control(.retire)) == .accepted)
            #expect(f.staged); #expect(await f.policy.reservedBytes == 140)
            #expect(try await c.sendLive(.packet(try .init(scope: f.scope, sequence: 0, startSample: 0, samples: [Float](repeating: 1, count: 160)))) == .accepted)
            #expect(try await c.sendLive(.barrier(.init(scope: f.scope, nextPacketSequence: 1, sampleEnd: 160, kind: .utterance))) == .accepted)
            try #require(await DXuntil { audit.count("commit") == 1 }); #expect(audit.count("error") == 0)
            #expect(f.staged); #expect(await f.policy.reservedBytes == 140)
            await c.shutdownLiveAndWaitForExit()
            #expect(!f.staged); #expect(await f.policy.reservedBytes == 100)
            await f.finish(c)
        } catch { await f.finish(c); throw error }
    }

    @Test func decodedEventOverflowSealsPublicationButKeepsValidatedNativeProof() async throws {
        let f = try await DXfixture.make(), audit = DXaudit(), c = try await f.start(mode: "live-duplex-event-overflow", audit: audit)
        do {
            let optional = try await f.open(c); var iterator = optional.makeAsyncIterator()
            #expect(try await c.sendDiarizationControl(f.control(.prepare(epochID: f.scope.epochID))) == .accepted)
            _ = try await iterator.next()
            guard case .ready(_, let context) = try await iterator.next()?.payload else { throw LiveProtocolError.invalidPacket }
            #expect(try await c.sendDiarizationControl(f.control(.acknowledge(contextID: context))) == .accepted)
            // Leave the actual decoded queue full while its serial raw consumer
            // validates the remaining packet and joined retirement receipt.
            try #require(await DXuntil { await f.policy.reservedBytes == 100 }); #expect(!f.staged)
            do { while try await iterator.next() != nil {}; Issue.record("decoded overflow did not seal publication") }
            catch { #expect(error as? LiveProtocolError == .outputLimit) }
            #expect(await c.livePendingCount == 0)
            #expect(try await c.sendLive(.cancel(f.scope.identity)) == .accepted)
            try #require(await DXuntil { audit.count("finished") == 1 }); #expect(audit.count("error") == 0)
            await f.finish(c)
        } catch { await f.finish(c); throw error }
    }

    @Test func exactEpochInventoryRemainsBoundedAndRejectedCandidatesNeverGainAuthority() async throws {
        let f = try await DXfixture.make()
        let authority = LiveOptionalEpochAuthority(f.begin)
        let rejected = LiveEpoch(id: UUID(), source: .system, engineRevision: "fixture", language: "en", meetingOriginNanoseconds: nil)
        #expect(authority.reserve(rejected)); authority.resolve(rejected.id, accepted: false)
        #expect(!authority.accepted(rejected.id)); #expect(!authority.reserve(rejected))
        for _ in 0..<62 {
            let epoch = LiveEpoch(id: UUID(), source: .system, engineRevision: "fixture", language: "en", meetingOriginNanoseconds: nil)
            #expect(authority.reserve(epoch)); authority.resolve(epoch.id, accepted: true); #expect(authority.accepted(epoch.id))
        }
        let extra = LiveEpoch(id: UUID(), source: .system, engineRevision: "fixture", language: "en", meetingOriginNanoseconds: nil)
        #expect(!authority.reserve(extra)); #expect(authority.accepted(f.scope.epochID))
        #expect(await authority.awaitAcceptance(UUID()) == false)
        authority.close(); #expect(!authority.accepted(f.scope.epochID))
        await f.assets.retire(owner: f.owner)?.value; await f.policy.release(f.lease); try? FileManager.default.removeItem(at: f.root)
    }

    @Test func concurrentPrepareCanDispatchOnlyOneActualWireControl() async throws {
        let f = try await DXfixture.make(), c = try await f.start()
        var commands: [Task<LiveSessionReply, Error>] = []
        do {
            let optional = try await f.open(c); var iterator = optional.makeAsyncIterator()
            for _ in 0..<4 { commands.append(Task { try await c.sendDiarizationControl(f.control(.prepare(epochID: f.scope.epochID))) }) }
            var accepted = 0, refused = 0
            for command in commands {
                switch await command.result {
                case .success(.accepted): accepted += 1
                case .success: Issue.record("duplicate prepare reached the helper")
                case .failure(let error): #expect(error as? LiveProtocolError == .staleScope); refused += 1
                }
            }
            #expect(accepted == 1 && refused == 3)
            #expect(try String(contentsOf: f.root.appendingPathComponent("native-entered"), encoding: .utf8) == "1")
            _ = try await iterator.next()
            guard case .ready = try await iterator.next()?.payload else { throw LiveProtocolError.invalidPacket }
            #expect(try await c.sendDiarizationControl(f.control(.retire)) == .accepted)
            await f.finish(c)
        } catch { for command in commands { command.cancel() }; await f.finish(c); for command in commands { _ = await command.result }; throw error }
    }
}
