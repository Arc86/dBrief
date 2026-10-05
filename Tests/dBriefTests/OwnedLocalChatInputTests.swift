import Darwin
import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Owned local chat physical input", .serialized)
@MainActor
struct OwnedLocalChatInputTests {
    private func context(_ f: LiveArtifactFixture, registry: LiveRecordingSessionRegistry) throws -> TranscriptContextSnapshot {
        let entry = try registry.registerLegacy(f.identity)
        try entry.artifacts.appendLegacy([.init(start: 0, end: 1, text: "Exact owned input fixture", speaker: "You")])
        return try entry.artifacts.legacyContext()
    }
    private nonisolated func flag(_ f: LiveArtifactFixture, _ n: Int) -> URL { f.root.appendingPathComponent("input-flag-\(n)") }
    private func connection(_ f: LiveArtifactFixture, policy: LiveModelResourcePolicy,
        afterAdmission: (@Sendable () async -> Void)? = nil, write: @escaping @Sendable (Bool) -> Void = { _ in },
        controls: @escaping @Sendable (Bool) -> Void = { _ in }, termination: @escaping @Sendable () async -> Void = {}) -> MLHostConnection {
        MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"), supportBase: f.root,
            environment: Dictionary(uniqueKeysWithValues: [("STUB_MODE", "owned-input-stall")] +
                (1...7).map { ("STUB_FLAG_\($0)", flag(f, $0).path) }),
            resourceAdmission: .init(policy: policy, measurement: { .init(availableBytes: 2_000, pressure: .normal) }),
            terminationDelivery: termination, testingAfterOwnedChatAdmission: afterAdmission,
            testingOwnedInputWrite: write, testingOwnedControl: controls)
    }

    @Test func worstEscapingUTF8AndFrameHeaderBoundPreserveExactProtocolValues() throws {
        // Independent numeric acceptance derived from the documented transport
        // envelope, not the implementation's constant or private fields.
        for text in [String(repeating: "\u{0}", count: 86_698), String(repeating: "\"", count: 86_698),
                     String(repeating: "\\", count: 86_698), String(repeating: "🙂", count: 21_674)] {
            let id = UUID(), frame = try MLHostConnection.ownedInputFrame(.init(id: id,
                request: .chatStream(systemPrompt: text, userMessage: "")))
            let size = frame.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ((3 - $1.offset) * 8) }
            #expect(Int(size) == frame.count - 4 && frame.count <= 524_288)
            let decoded = try JSONDecoder().decode(RequestEnvelope.self, from: frame.dropFirst(4))
            #expect(decoded.id == id)
            guard case let .chatStream(systemPrompt, userMessage) = decoded.request else { Issue.record("Wrong wire case"); return }
            #expect(systemPrompt == text && userMessage.isEmpty)
        }
        for text in [String(repeating: "\u{0}", count: 86_699), String(repeating: "🙂", count: 21_675)] {
            #expect(throws: ChatStreamEndError.self) {
                try MLHostConnection.ownedInputFrame(.init(id: UUID(), request: .chatStream(systemPrompt: text, userMessage: "")))
            }
        }
        #expect(throws: MLHostError.self) {
            try MLHostConnection.ownedInputFrame(.init(id: UUID(), request: .forceUnload))
        }
    }

    @Test(arguments: [false, true])
    func invalidOwnedWireInputCannotAcquirePermitOrLaunchHelper(nonChat: Bool) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var snapshot: TranscriptContextSnapshot? = try context(f, registry: registry)
        let policy = LiveModelResourcePolicy(profiles: []), connection = connection(f, policy: policy)
        let request: MLRequest = nonChat ? .forceUnload : .chatStream(systemPrompt: String(repeating: "x", count: 86_699), userMessage: "")
        func start(_ value: TranscriptContextSnapshot) async -> ChatStreamRun {
            await connection.startStream(request, ownership: value.contextOwnership)
        }
        let run = await start(try #require(snapshot)); snapshot = nil
        await #expect(throws: (any Error).self) { for try await _ in run.stream {} }
        await run.waitForReturn()
        #expect(await policy.jobCount == 0)
        #expect(!FileManager.default.fileExists(atPath: flag(f, 1).path))
        try registry.retire(f.identity)
        #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
        await connection.shutdown(); await connection.waitForShutdown()
    }

    @Test(arguments: [OwnedEncodingPhase.measurement, .retirement, .postAdmission])
    func heldActualAdmissionsCannotAccumulateEncodedFrames(phase: OwnedEncodingPhase) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var snapshot: TranscriptContextSnapshot? = try context(f, registry: registry)
        let gate = OwnedEncodingGate(), probe = OwnedInputProbe(), policy = LiveModelResourcePolicy(profiles: [])
        let environment = Dictionary(uniqueKeysWithValues: [("STUB_MODE", "owned-input-stall")] +
            (1...7).map { ("STUB_FLAG_\($0)", flag(f, $0).path) })
        let held: @Sendable () async -> Void = { await gate.hold() }
        let measurement: @Sendable () async throws -> LiveResourceMeasurement = {
            if phase == .measurement { await gate.hold() }
            return .init(availableBytes: 2_000, pressure: .normal)
        }
        let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"), supportBase: f.root,
            environment: environment, resourceAdmission: .init(policy: policy, measurement: measurement),
            retirementWaitDelivery: phase == .retirement ? held : nil,
            testingAfterOwnedChatAdmission: phase == .postAdmission ? held : nil,
            testingOwnedInputEncoded: { bytes in probe.mark("encoded"); probe.add("frame-bytes", bytes) })
        if phase == .retirement {
            try Data().write(to: flag(f, 2))
            _ = try await connection.call(.forceUnload) // Actual old child read/reply.
            #expect(FileManager.default.fileExists(atPath: flag(f, 1).path))
            await connection.shutdown(); try Data().write(to: flag(f, 4)); await connection.waitForShutdown()
            try FileManager.default.removeItem(at: flag(f, 1))
        }
        let count = phase == .postAdmission ? 1 : 80
        // All starts share caller-owned strings and one original context wrapper;
        // the observation records only frames allocated by the actual connection.
        let request = MLRequest.chatStream(systemPrompt: String(repeating: "\u{0}", count: 86_698), userMessage: "")
        func start(_ value: TranscriptContextSnapshot) -> [Task<ChatStreamRun, Never>] {
            (0..<count).map { _ in Task { await connection.startStream(request, ownership: value.contextOwnership) } }
        }
        var starts = start(try #require(snapshot)); snapshot = nil
        do {
            try await f.eventually { await gate.arrivals == count }
            #expect(probe.count("encoded") == 0)
            #expect(probe.count("frame-bytes") < 2 * 1_024 * 1_024)
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            #expect(await policy.jobCount == (phase == .postAdmission ? 1 : 0))
            #expect(!FileManager.default.fileExists(atPath: flag(f, 3).path) && !FileManager.default.fileExists(atPath: flag(f, 5).path))
            if phase != .postAdmission { #expect(!FileManager.default.fileExists(atPath: flag(f, 1).path)) }
            try registry.retire(f.identity)
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            await gate.release()
            for launch in starts {
                let run = await launch.value
                await #expect(throws: (any Error).self) { for try await _ in run.stream {} }
                await run.waitForReturn()
            }
            starts.removeAll()
            #expect(probe.count("encoded") == 0)
            #expect(!FileManager.default.fileExists(atPath: flag(f, 5).path))
            #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
            await connection.shutdown(); try Data().write(to: flag(f, 4)); await connection.waitForShutdown()
            #expect(await policy.jobCount == 0)
        } catch {
            await gate.release(); try? Data().write(to: flag(f, 2)); try? Data().write(to: flag(f, 4))
            for launch in starts { launch.cancel(); (await launch.value).cancel() }
            await connection.shutdown(); await connection.waitForShutdown(); throw error
        }
    }

    @Test func actualChildExitCannotRefundWhileOwnedWriterReturnIsHeld() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var snapshot: TranscriptContextSnapshot? = try context(f, registry: registry)
        let hold = OwnedInputHold(), probe = OwnedInputProbe(), policy = LiveModelResourcePolicy(profiles: [])
        let connection = connection(f, policy: policy, write: { if !$0 { hold.enterAndWait() } },
            termination: { probe.mark("physical-exit") })
        func start(_ value: TranscriptContextSnapshot) -> Task<ChatStreamRun, Never> {
            Task { await connection.startStream(.chatStream(systemPrompt: String(repeating: "x", count: 72 * 1_024),
                userMessage: "Held actual writer return"), ownership: value.contextOwnership) }
        }
        let launch = start(try #require(snapshot)); snapshot = nil
        var returned: Task<Void, Never>?, closed: Task<Void, Never>?
        do {
            try await f.eventually { (Int((try? String(contentsOf: flag(f, 3), encoding: .utf8)) ?? "") ?? 0) > 0 }
            try registry.retire(f.identity)
            try await f.eventually { hold.entered }
            let run = await launch.value; run.cancel(); await connection.shutdown()
            returned = Task { await run.waitForReturn(); probe.mark("returned") }
            closed = Task { await connection.waitForShutdown(); probe.mark("closed") }
            try Data().write(to: flag(f, 4))
            try await f.eventually { probe.has("physical-exit") }
            #expect(await policy.jobCount == 1)
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            #expect(!probe.has("returned") && !probe.has("closed") && !hold.timedOut)
            #expect(!FileManager.default.fileExists(atPath: flag(f, 5).path))
            hold.release(); await returned?.value; await closed?.value
            #expect(await policy.jobCount == 0)
            try await f.eventually { @MainActor in registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes }
            #expect(!hold.timedOut)
        } catch {
            hold.release(); try? Data().write(to: flag(f, 2)); try? Data().write(to: flag(f, 4))
            (await launch.value).cancel(); await connection.shutdown(); await connection.waitForShutdown()
            await returned?.value; await closed?.value; throw error
        }
    }

    @Test(arguments: [false, true])
    func actualPostHelperAdmissionRetirementRejectsFrameButKeepsResidentClaim(cancel: Bool) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var snapshot: TranscriptContextSnapshot? = try context(f, registry: registry)
        let gate = OwnedInputGate(), policy = LiveModelResourcePolicy(profiles: [])
        let connection = connection(f, policy: policy, afterAdmission: { await gate.hold() })
        func start(_ value: TranscriptContextSnapshot) -> Task<ChatStreamRun, Never> {
            Task { await connection.startStream(.chatStream(systemPrompt: "Exact private evidence", userMessage: "Held admission"), ownership: value.contextOwnership) }
        }
        let launch = start(try #require(snapshot)); snapshot = nil
        do {
            try await f.eventually { await gate.entered }
            try await f.eventually { FileManager.default.fileExists(atPath: flag(f, 1).path) }
            #expect(await policy.jobCount == 1)
            try registry.retire(f.identity); if cancel { launch.cancel() }
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            await gate.release(); let run = await launch.value
            await #expect(throws: CancellationError.self) { for try await _ in run.stream {} }
            await run.waitForReturn()
            #expect(await policy.jobCount == 1)
            #expect(!FileManager.default.fileExists(atPath: flag(f, 3).path) && !FileManager.default.fileExists(atPath: flag(f, 5).path))
            #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
            await connection.shutdown()
            #expect(await policy.jobCount == 1)
            try Data().write(to: flag(f, 4)); await connection.waitForShutdown()
            #expect(await policy.jobCount == 0)
        } catch {
            await gate.release(); try? Data().write(to: flag(f, 2)); try? Data().write(to: flag(f, 4))
            (await launch.value).cancel(); await connection.shutdown(); await connection.waitForShutdown(); throw error
        }
    }

    @Test func heldOldAdmissionCannotDispatchIntoActualReplacementHelper() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var snapshot: TranscriptContextSnapshot? = try context(f, registry: registry)
        let gate = OwnedInputGate(), policy = LiveModelResourcePolicy(profiles: [])
        let connection = connection(f, policy: policy, afterAdmission: { await gate.hold() })
        func start(_ value: TranscriptContextSnapshot) -> Task<ChatStreamRun, Never> {
            Task { await connection.startStream(.chatStream(systemPrompt: "Obsolete owned frame", userMessage: "Old"), ownership: value.contextOwnership) }
        }
        let old = start(try #require(snapshot)); snapshot = nil
        do {
            try await f.eventually { await gate.entered }
            await connection.shutdown(); try Data().write(to: flag(f, 4)); await connection.waitForShutdown()
            #expect(await policy.jobCount == 0)
            try FileManager.default.removeItem(at: flag(f, 4)); try Data().write(to: flag(f, 2))
            let replacement = await connection.startStream(.chatStream(systemPrompt: "Replacement", userMessage: "New"))
            for try await _ in replacement.stream {}; await replacement.waitForReturn()
            let dispatched = try Data(contentsOf: flag(f, 5))
            await gate.release(); let oldRun = await old.value
            await #expect(throws: CancellationError.self) { for try await _ in oldRun.stream {} }
            await oldRun.waitForReturn()
            #expect(try Data(contentsOf: flag(f, 5)) == dispatched)
            #expect(await policy.jobCount == 1)
            try registry.retire(f.identity)
            #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
            await connection.shutdown(); try Data().write(to: flag(f, 4)); await connection.waitForShutdown()
        } catch {
            await gate.release(); try? Data().write(to: flag(f, 2)); try? Data().write(to: flag(f, 4))
            (await old.value).cancel(); await connection.shutdown(); await connection.waitForShutdown(); throw error
        }
    }

    @Test func lateOwnedCancelCannotReachActualReplacementGeneration() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var snapshot: TranscriptContextSnapshot? = try context(f, registry: registry)
        let policy = LiveModelResourcePolicy(profiles: []), probe = OwnedInputProbe()
        let connection = connection(f, policy: policy, controls: { probe.mark($0 ? "accepted" : "ignored") })
        try Data().write(to: flag(f, 2))
        func start(_ value: TranscriptContextSnapshot) async -> ChatStreamRun {
            await connection.startStream(.chatStream(systemPrompt: "Owned first generation", userMessage: "First"), ownership: value.contextOwnership)
        }
        let oldRun = await start(try #require(snapshot)); snapshot = nil
        do {
            for try await _ in oldRun.stream {}; await oldRun.waitForReturn()
            let oldID = try #require(try String(contentsOf: flag(f, 5), encoding: .utf8).split(separator: "\n").first)
            await connection.shutdown(); try Data().write(to: flag(f, 4)); await connection.waitForShutdown()
            try FileManager.default.removeItem(at: flag(f, 4)); try? FileManager.default.removeItem(at: flag(f, 7))
            let replacement = await connection.startStream(.chatStream(systemPrompt: "Unowned replacement", userMessage: "Second"))
            for try await _ in replacement.stream {}; await replacement.waitForReturn()
            let ignored = probe.count("ignored")
            oldRun.cancel()
            try await f.eventually { probe.count("ignored") > ignored }
            _ = try await connection.call(.forceUnload) // Actual ordered child reply.
            let controls = (try? String(contentsOf: flag(f, 7), encoding: .utf8)) ?? ""
            #expect(!controls.split(separator: "\n").contains(oldID))
            #expect(await policy.jobCount == 1)
            try registry.retire(f.identity)
            // Keeping completed oldRun alive must not keep a source Pin.
            #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
            withExtendedLifetime(oldRun) {}
            await connection.shutdown(); try Data().write(to: flag(f, 4)); await connection.waitForShutdown()
        } catch {
            try? Data().write(to: flag(f, 4)); oldRun.cancel()
            await connection.shutdown(); await connection.waitForShutdown(); throw error
        }
    }

    @Test func actualFrameReturnAndSharedCloseRetainOwnershipThroughHeldWriterCallback() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var snapshot: TranscriptContextSnapshot? = try context(f, registry: registry)
        let pipe = Pipe(), hold = OwnedInputHold(), probe = OwnedInputProbe(), written = ChatStreamReturn()
        let writer = LivePipeWriter(handle: pipe.fileHandleForWriting, nonblockingWrites: true,
            testingMandatoryWrite: { if !$0 { hold.enterAndWait() } }, failed: { probe.mark("failed") })
        #expect(writer.isReady)
        let frame = FrameCodec.encode(Data([1, 2, 3]))
        func enqueue(_ value: TranscriptContextSnapshot) -> Bool { writer.enqueue(frame, ownership: value.contextOwnership, returned: written) }
        #expect(enqueue(try #require(snapshot))); snapshot = nil
        do {
            try await f.eventually { hold.entered }
            #expect(writer.residentBytes == frame.count)
            #expect(!writer.enqueue(Data(repeating: 1, count: 524_288)))
            try registry.retire(f.identity)
            let first = writer.retire(), second = writer.retire()
            let frameJoin = Task { await written.wait(); probe.mark("frame") }
            let closeJoin = Task { await first.value; await second.value; probe.mark("close") }
            var actual = [UInt8](repeating: 0, count: frame.count)
            #expect(Darwin.read(pipe.fileHandleForReading.fileDescriptor, &actual, actual.count) == frame.count && Data(actual) == frame)
            #expect(!probe.has("frame") && !probe.has("close"))
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            hold.release(); await frameJoin.value; await closeJoin.value
            #expect(writer.residentBytes == 0 && !probe.has("failed") && !hold.timedOut)
            try await f.eventually { @MainActor in registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes }
        } catch { hold.release(); await writer.retire().value; throw error }
        try? pipe.fileHandleForReading.close()
    }

    @Test func actualBrokenFIFOFailureStillCompletesSharedCloseAndReleasesOwner() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var snapshot: TranscriptContextSnapshot? = try context(f, registry: registry)
        let pipe = Pipe(), hold = OwnedInputHold(), probe = OwnedInputProbe()
        let writer = LivePipeWriter(handle: pipe.fileHandleForWriting, nonblockingWrites: true,
            testingMandatoryWrite: { if $0 { hold.enterAndWait() } }, failed: { probe.mark("failed") })
        func enqueue(_ value: TranscriptContextSnapshot) -> Bool { writer.enqueue(Data([1, 2, 3]), ownership: value.contextOwnership) }
        #expect(enqueue(try #require(snapshot))); snapshot = nil
        do {
            try await f.eventually { hold.entered }
            try pipe.fileHandleForReading.close(); hold.release()
            try await f.eventually { probe.has("failed") }
            await writer.retire().value; await writer.retire().value
            try registry.retire(f.identity)
            try await f.eventually { @MainActor in registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes }
            #expect(writer.residentBytes == 0 && probe.count("failed") == 1 && !hold.timedOut)
        } catch { hold.release(); await writer.retire().value; throw error }
    }

    @Test func actualFullStdinCannotBlockMainActorRetirementAndRetainsClaimsUntilChildExit() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var snapshot: TranscriptContextSnapshot? = try context(f, registry: registry)
        let policy = LiveModelResourcePolicy(profiles: []), connection = connection(f, policy: policy)
        func start(_ value: TranscriptContextSnapshot) -> Task<ChatStreamRun, Never> {
            Task { await connection.startStream(.chatStream(systemPrompt: String(repeating: "x", count: 72 * 1_024),
                userMessage: "Synthetic physical FIFO proof"), ownership: value.contextOwnership) }
        }
        let launch = start(try #require(snapshot)); snapshot = nil
        var watchdog: Task<Void, Never>?, returned: Task<Void, Never>?, closed: Task<Void, Never>?
        let returnProbe = OwnedInputProbe(), closeProbe = OwnedInputProbe()
        do {
            try await f.eventually {
                let occupied = Int((try? String(contentsOf: flag(f, 3), encoding: .utf8)) ?? "") ?? 0
                return occupied > 0 && occupied < 72 * 1_024
            }
            #expect(FileManager.default.fileExists(atPath: flag(f, 1).path))
            // Independent of MainActor and the connection actor. This makes the
            // causal blocking regression unwind while retaining its failures.
            let readRelease = flag(f, 2)
            watchdog = Task.detached {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                try? Data("watchdog".utf8).write(to: readRelease, options: .atomic)
            }
            try registry.retire(f.identity) // Actual MainActor invalidation.
            let sentinel = Task { @MainActor in returnProbe.mark("sentinel") }; await sentinel.value
            #expect(!FileManager.default.fileExists(atPath: readRelease.path))
            #expect(returnProbe.has("sentinel"))
            let run = await launch.value
            run.cancel(); await connection.shutdown()
            returned = Task { await run.waitForReturn(); returnProbe.mark("returned") }
            closed = Task { await connection.waitForShutdown(); closeProbe.mark("closed") }
            #expect(await policy.jobCount == 1)
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            #expect(!returnProbe.has("returned") && !closeProbe.has("closed"))
            #expect(!FileManager.default.fileExists(atPath: flag(f, 5).path))
            watchdog?.cancel(); await watchdog?.value
            try Data("release".utf8).write(to: readRelease, options: .atomic)
            try await f.eventually { FileManager.default.fileExists(atPath: flag(f, 6).path) }
            #expect(!FileManager.default.fileExists(atPath: flag(f, 5).path))
            #expect(await policy.jobCount == 1)
            #expect(!returnProbe.has("returned") && !closeProbe.has("closed"))
            try Data().write(to: flag(f, 4))
            await returned?.value; await closed?.value
            #expect(await policy.jobCount == 0)
            try await f.eventually { @MainActor in registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes }
        } catch {
            watchdog?.cancel(); await watchdog?.value
            try? Data().write(to: flag(f, 2)); try? Data().write(to: flag(f, 4))
            (await launch.value).cancel(); await connection.shutdown(); await connection.waitForShutdown()
            await returned?.value; await closed?.value
            throw error
        }
    }
}

private final class OwnedInputProbe: @unchecked Sendable {
    private let lock = NSLock(); private var marks: [String: Int] = [:]
    func mark(_ name: String) { lock.withLock { marks[name, default: 0] += 1 } }
    func add(_ name: String, _ value: Int) { lock.withLock { marks[name, default: 0] += value } }
    func has(_ name: String) -> Bool { count(name) > 0 }
    func count(_ name: String) -> Int { lock.withLock { marks[name, default: 0] } }
}

private actor OwnedInputGate {
    private(set) var entered = false
    private var released = false, waiter: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; if !released { await withCheckedContinuation { waiter = $0 } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
private final class OwnedInputHold: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var arrived = false, released = false, timeout = false
    var entered: Bool { lock.withLock { arrived } }
    var timedOut: Bool { lock.withLock { timeout } }
    func enterAndWait() {
        lock.withLock { arrived = true }
        let result = semaphore.wait(timeout: .now() + TestTiming.asyncDeadlineSeconds)
        lock.withLock { timeout = result == .timedOut }
    }
    func release() {
        let signal = lock.withLock { if released { return false }; released = true; return true }
        if signal { semaphore.signal() }
    }
}

enum OwnedEncodingPhase: Sendable, Equatable { case measurement, retirement, postAdmission }
private actor OwnedEncodingGate {
    private(set) var arrivals = 0
    private var released = false, waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        arrivals += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
