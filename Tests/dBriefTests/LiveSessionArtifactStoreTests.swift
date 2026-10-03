import Foundation
import Testing
import dBriefWire
@testable import dBrief

// The artifact suites exercise the shared synchronous disk-mutation boundary.
// Keep independent filesystem fixtures serial; their held-task races remain
// concurrent inside each test without flooding unrelated IPC timing fixtures.
@Suite("Live artifact filesystem", .serialized)
struct LiveArtifactDurabilityTests {}

extension LiveArtifactDurabilityTests {
@Suite("Live history durable writer")
struct LiveSessionArtifactStoreTests {
    @Test func aHeldSaveCannotOverwriteTheLaterAcceptedRevision() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .sourceChat)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await gate.enter($0) })
        let first = Task { try await writer.saveChat(f.history("First"), revision: 1) }
        var later: Task<Void, Error>?
        do {
            try await gate.waitForArrival()
            let second = Task { try await writer.saveChat(f.history("Second"), revision: 2) }
            later = second
            try await f.eventually { await writer.status().acceptedChatRevision == 2 }
            #expect(await writer.status().durableChatRevision == 0)
            await gate.release()
            try await first.value; try await second.value
            let restored = try await writer.recover()
            #expect(restored.chat?.messages.last?.content == "Second")
            #expect(restored.chat?.revision == 2 && restored.chat?.identity == f.identity)
            await #expect(throws: LiveArtifactError.staleRevision) { try await writer.saveChat(f.history("Old"), revision: 1) }
        } catch {
            first.cancel(); later?.cancel(); await gate.release()
            _ = try? await first.value; _ = try? await later?.value
            throw error
        }
    }

    @Test func equalRevisionRequiresTheExactSameCanonicalContent() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        let history = f.history("Exact duplicate")
        try await writer.saveChat(history, revision: 1)
        try await writer.saveChat(history, revision: 1)
        await #expect(throws: LiveArtifactError.revisionConflict) { try await writer.saveChat(f.history("Different"), revision: 1) }
        #expect(try await writer.recover().chat?.messages.last?.content == "Exact duplicate")
    }

    @Test func aWriteFailureReportsLagAndRetryPreservesTheLatestChat() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let fault = LiveArtifactFault(stage: .sourceChat)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await fault.check($0) })
        await #expect(throws: LiveArtifactFixtureFailure.injected) { try await writer.saveChat(f.history("Unsaved"), revision: 1) }
        let status = await writer.status()
        #expect(status.acceptedChatRevision == 1 && status.durableChatRevision == 0 && status.failure != nil)
        try await writer.retry()
        #expect(try await writer.recover().chat?.messages.last?.content == "Unsaved")
        #expect(await writer.status().failure == nil)
    }

    @Test(arguments: ["corrupt", "unsupported", "foreign"])
    func unrecognizedExistingChatIsNeverOverwritten(kind: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        try FileManager.default.createDirectory(at: f.session, withIntermediateDirectories: true)
        let original: Data
        if kind == "corrupt" { original = Data("{broken".utf8) }
        else {
            var history = f.history("Keep")
            history.version = kind == "unsupported" ? 99 : ChatHistory.currentVersion
            history.identity = kind == "foreign" ? .init(recordingID: UUID(), captureSessionID: UUID()) : f.identity
            history.revision = 1
            original = try JSONEncoder().encode(history)
        }
        try original.write(to: f.session.appendingPathComponent("chat.json"))
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        await #expect(throws: (any Error).self) { try await writer.saveChat(f.history("Replacement"), revision: 2) }
        #expect(try Data(contentsOf: f.session.appendingPathComponent("chat.json")) == original)
    }

    @Test func recoveredStreamingAnswersAreInterruptedWithoutInventingBasis() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveChat(ChatHistory(messages: [ChatMessage(role: .assistant, content: "Partial", outcome: .streaming)]), revision: 1)
        let restored = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover()
        #expect(restored.chat?.messages.first?.outcome == .interrupted)
        #expect(restored.chat?.messages.first?.basis == nil)
    }

    @Test func checkpointRetainsUnalignedAndAheadOfCutoffCommittedHistory() async throws {
        let f = LiveTranscriptFixture(), mic = f.epoch(), system = f.epoch(.system, origin: nil)
        let store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: mic) == .accepted)
        #expect(await store.beginEpoch(owner: f.identity, epoch: system) == .accepted)
        #expect(await store.admit(f.event(mic, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(mic, 1, .committed(f.segment(mic, 0, 0, 1, "Aligned")))) == .accepted)
        #expect(await store.admit(f.event(system, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(system, 1, .committed(f.segment(system, 0, 0, 1, "Unaligned")))) == .accepted)
        let checkpoint = await store.checkpoint()
        let decoded = try JSONDecoder().decode(LiveTranscriptCheckpoint.self, from: JSONEncoder().encode(checkpoint))
        let restored = try LiveTranscriptStore(restoring: decoded)
        let originalSnapshot = await store.snapshot(), restoredSnapshot = await restored.snapshot()
        #expect(restoredSnapshot == originalSnapshot)
        #expect(await restored.projection().isClosed)
        let unaligned = await restored.snapshot(selection: .evidence([f.segment(system, 0, 0, 1, "Unaligned").id], includeUnaligned: true))
        #expect(unaligned.segments.map(\.text) == ["Unaligned"] && unaligned.scope == .unalignedEvidence)
        #expect(await restored.beginEpoch(owner: f.identity, epoch: f.epoch()) == .rejected(.closed))
    }

    @Test func checkpointRetainsTextAheadOfTheSharedCutoff() async throws {
        let f = LiveTranscriptFixture(), mic = f.epoch(), system = f.epoch(.system)
        let store = LiveTranscriptStore(identity: f.identity)
        _ = await store.beginEpoch(owner: f.identity, epoch: mic)
        _ = await store.beginEpoch(owner: f.identity, epoch: system)
        _ = await store.admit(f.event(mic, 0, f.progress(2)))
        _ = await store.admit(f.event(mic, 1, .committed(f.segment(mic, 0, 0, 2, "Ahead"))))
        _ = await store.admit(f.event(system, 0, f.progress(1)))
        _ = await store.admit(f.event(system, 1, f.settlement(system, 0, 1, .processedSilence)))
        let checkpoint = await store.checkpoint()
        #expect(checkpoint.segments.map(\.text) == ["Ahead"])
        let restored = try LiveTranscriptStore(restoring: checkpoint)
        #expect(await restored.projection().segments.map(\.text) == ["Ahead"])
        #expect(await restored.snapshot().segments.isEmpty)
        #expect(await restored.snapshot().cutoffNanoseconds == 1_000_000_000)
    }

    @Test func saturationCoalescesPayloadsAndReservesBindingAdmission() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .sourceChat)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await gate.enter($0) })
        var writes: [Task<Void, Error>] = [Task { try await writer.saveChat(f.history("1"), revision: 1) }]
        var binding: Task<Void, Error>?
        do {
            try await gate.waitForArrival()
            for revision in UInt64(2)...64 {
                writes.append(Task { try await writer.saveChat(f.history(String(revision)), revision: revision) })
                try await f.eventually { await writer.status().acceptedChatRevision == revision }
            }
            let status = await writer.status()
            #expect(status.admittedWriteWaiters == 64 && status.retainedPayloads <= 2)
            #expect(status.queuedEncodedBytes < 16_384)
            await #expect(throws: LiveArtifactError.queueFull) { try await writer.saveChat(f.history("65"), revision: 65) }
            binding = Task { try await writer.bind(to: f.audio) }
            try await f.eventually { await writer.status().admittedControls == 1 }
            await gate.release()
            for write in writes { try await write.value }
            try await binding?.value
            #expect(try await writer.recover().chat?.messages.last?.content == "64")
        } catch {
            for write in writes { write.cancel() }
            binding?.cancel(); await gate.release()
            for write in writes { _ = try? await write.value }
            _ = try? await binding?.value
            throw error
        }
    }

    @Test func clearIsAnOrderingBarrierBeforeTheNextSend() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .sourceChat)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await gate.enter($0) })
        let first = Task { try await writer.saveChat(f.history("Old"), revision: 1) }
        var clear: Task<Void, Error>?, next: Task<Void, Error>?
        do {
            try await gate.waitForArrival()
            clear = Task { try await writer.clearChat(revision: 2) }
            try await f.eventually { await writer.status().acceptedChatRevision == 2 }
            next = Task { try await writer.saveChat(f.history("New"), revision: 3) }
            try await f.eventually { await writer.status().acceptedChatRevision == 3 }
            await gate.release()
            try await first.value; try await clear?.value; try await next?.value
            #expect(try await writer.recover().chat?.messages.last?.content == "New")
        } catch {
            first.cancel(); clear?.cancel(); next?.cancel(); await gate.release()
            _ = try? await first.value; _ = try? await clear?.value; _ = try? await next?.value
            throw error
        }
    }

    @Test func aggregateEscapingIsRejectedBeforeEncodingAllocatesItsOutput() throws {
        let probe = LiveArtifactEncodingProbe()
        let block = String(repeating: "\n", count: 1_024 * 1_024)
        let history = ChatHistory(messages: (0..<8).map { _ in ChatMessage(role: .user, content: block) })
        #expect(throws: LiveArtifactError.artifactTooLarge) {
            _ = try LiveArtifactEncoding.encode(history, limit: 32 * 1_024 * 1_024, beforeEncoding: { probe.enter() })
        }
        #expect(probe.count == 0)
        let ordinary = ChatHistory(messages: [ChatMessage(role: .user, content: "Unicode café \"quoted\"\nnext line")])
        let bytes = try LiveArtifactEncoding.encode(ordinary, limit: 32 * 1_024 * 1_024, beforeEncoding: { probe.enter() })
        #expect(try JSONDecoder().decode(ChatHistory.self, from: bytes) == ordinary && probe.count == 1)
    }

    @Test func revisionFeedRetainsOnlyTheLatestCommittedNotification() async throws {
        let f = LiveTranscriptFixture(), epoch = f.epoch(), store = LiveTranscriptStore(identity: f.identity)
        let stream = try await store.changes()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        _ = await store.beginEpoch(owner: f.identity, epoch: epoch)
        _ = await store.admit(f.event(epoch, 0, f.progress(1)))
        _ = await store.admit(f.event(epoch, 1, .committed(f.segment(epoch, 0, 0, 1))))
        #expect(await iterator.next() == 3)
    }

    @Test func emptyStringCollectionsIncludeTheirJSONSeparatorsInPreflight() throws {
        let probe = LiveArtifactEncodingProbe()
        let strings = [String](repeating: "", count: 4_096)
        let arrays = [[String]](repeating: strings, count: 120)
        #expect(throws: LiveArtifactError.artifactTooLarge) {
            _ = try LiveArtifactEncoding.encode(arrays, limit: 1_024 * 1_024, beforeEncoding: { probe.enter() })
        }
        #expect(probe.count == 0)
    }
}
}

private final class LiveArtifactEncodingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = 0
    var count: Int { lock.withLock { entered } }
    func enter() { lock.withLock { entered += 1 } }
}

struct LiveArtifactFixture: Sendable {
    let identity = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-artifacts-\(UUID())")
    var session: URL { root.appendingPathComponent(identity.captureSessionID.uuidString) }
    var audio: URL { root.appendingPathComponent("recording.wav") }
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Model-free media ownership fixture".utf8).write(to: audio)
        let metadata = RecordingMetadataPayload(recordingID: identity.recordingID, dateISO8601: "fixture", durationSeconds: 1,
            meetingTitle: "fixture", masterFileName: audio.lastPathComponent, segmentFileNames: [], warnings: [])
        try JSONEncoder().encode(metadata).write(to: audio.deletingPathExtension().appendingPathExtension("json"))
    }
    func history(_ text: String) -> ChatHistory { ChatHistory(messages: [ChatMessage(role: .user, content: text)]) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func eventually(_ check: @escaping @Sendable () async -> Bool) async throws {
        let end = ContinuousClock.now + TestTiming.asyncDeadline
        while ContinuousClock.now < end {
            if await check() { return }
            await Task.yield()
        }
        try #require(await check())
    }
}

enum LiveArtifactFixtureFailure: Error, Equatable { case injected }
actor LiveArtifactFault {
    let stage: LiveArtifactStage
    private var failed = false
    init(stage: LiveArtifactStage) { self.stage = stage }
    func check(_ value: LiveArtifactStage) throws {
        if value == stage && !failed { failed = true; throw LiveArtifactFixtureFailure.injected }
    }
}
actor LiveArtifactGate {
    let stage: LiveArtifactStage
    private var arrived = false, released = false, enabled: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    init(stage: LiveArtifactStage, initiallyEnabled: Bool = true) { self.stage = stage; self.enabled = initiallyEnabled }
    func enter(_ value: LiveArtifactStage) async throws {
        guard enabled, value == stage, !arrived else { return }
        arrived = true
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func waitForArrival() async throws {
        let end = ContinuousClock.now + TestTiming.asyncDeadline
        while !arrived, ContinuousClock.now < end { await Task.yield() }
        try #require(arrived)
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
    func arm() { enabled = true }
}
