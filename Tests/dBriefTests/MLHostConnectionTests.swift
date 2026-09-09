import Testing
import Foundation
import dBriefWire
@testable import dBrief

private func stubURL() -> URL {
    URL(fileURLWithPath: ".build/debug/dBriefMLHostStub")
}

@Suite struct MLHostConnectionTests {
    @Test func callReturnsResult() async throws {
        let conn = MLHostConnection(binaryURL: stubURL(),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "echo"])
        let event = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false, unloadAfter: true))
        guard case let .transcriptionResult(tr) = event else { Issue.record("no result"); return }
        #expect(tr.text == "echo")
        await conn.shutdown()
    }

    @Test func errorEventThrowsWireError() async {
        let conn = MLHostConnection(binaryURL: stubURL(),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "error"])
        await #expect(throws: WireError.self) {
            _ = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false, unloadAfter: true))
        }
        await conn.shutdown()
    }

    @Test func crashSurfacesHelperCrashedError() async {
        let conn = MLHostConnection(binaryURL: stubURL(),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "crash-once", "STUB_FLAG_1": uniqueFlagPath()])
        await #expect(throws: MLHostError.helperCrashed) {
            _ = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false, unloadAfter: true))
        }
        await conn.shutdown()
    }

    // Frame-ordering invariant: `.finished` must never overtake the result frame.
    // If it does, `call()` must resume throwing — the historical behavior was to
    // drop the pending entry and leak the continuation (a permanent silent hang).
    @Test func prematureFinishedThrowsInsteadOfHanging() async {
        let conn = MLHostConnection(binaryURL: stubURL(),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "finished-first"])
        // Race the call against a timeout with UNSTRUCTURED tasks and abandon the
        // loser. A task group cannot work here: it awaits all children, and the
        // pre-guard bug leaks the call's continuation with no recovery path (once
        // `ingest` drops the pending entry, not even shutdown/handleTermination
        // can resume it) — the group, and the suite, would hang forever.
        let (race, raceCont) = AsyncStream<Result<MLEvent, any Error>>.makeStream()
        Task {
            do {
                raceCont.yield(.success(try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false, unloadAfter: true))))
            } catch {
                raceCont.yield(.failure(error))
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            raceCont.yield(.failure(MLHostError.helperUnavailable))   // sentinel: timed out
        }
        var iterator = race.makeAsyncIterator()
        let outcome = await iterator.next()!
        guard case let .failure(error) = outcome else {
            Issue.record("expected call() to throw, got a value"); return
        }
        #expect(error as? MLHostError == .protocolViolation)
        await conn.shutdown()
    }

    // Multi-frame reply (the worst-hit real path, Parakeet + diarization):
    // the call resolves with the result and the interleaved `.state` frames
    // all arrive on the channel's state stream.
    @Test func multiFrameReplyResolvesWithResultAndDeliversStates() async throws {
        let conn = MLHostConnection(binaryURL: stubURL(),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "multi-frame"])
        let states = await conn.stateStream(for: .plugin)
        let event = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false, unloadAfter: true))
        guard case let .transcriptionResult(tr) = event else { Issue.record("no result"); return }
        #expect(tr.text == "multi")
        // Race against a timeout so missing state frames fail instead of hanging
        // (cancellation ends AsyncStream iteration, so both child tasks unwind).
        let counts = await withTaskGroup(of: (transcribing: Int, diarizing: Int)?.self) { group in
            group.addTask {
                var transcribing = 0, diarizing = 0
                for await state in states {
                    if case .transcribing = state { transcribing += 1 }
                    if case .diarizing = state { diarizing += 1 }
                    if transcribing + diarizing == 3 { break }
                }
                return (transcribing, diarizing)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil   // timed out
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        #expect(counts?.transcribing == 1)
        #expect(counts?.diarizing == 2)
        await conn.shutdown()
    }
}


private final class ScopedProgressAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ state: LocalAIPluginState) {
        if case .newSegments(let segments) = state {
            lock.withLock { values.append(contentsOf: segments.map(\.text)) }
        }
    }
    var texts: [String] { lock.withLock { values } }
}

extension MLHostConnectionTests {
    @Test func scopedCallsRejectPreviousAndUnattributedProgress() async throws {
        let conn = MLHostConnection(binaryURL: stubURL(), supportBase: URL(fileURLWithPath: "/tmp"),
            environment: ["STUB_MODE": "scoped-progress"])
        let first = ScopedProgressAudit(), second = ScopedProgressAudit()
        for audit in [first, second] {
            _ = try await MLProgress.$sink.withValue({ audit.append($0) }) {
                try await conn.call(.transcribe(path: "/synthetic.wav", initialPrompt: nil,
                    config: .default, safeMode: false, unloadAfter: true))
            }
        }
        #expect(first.texts == ["current"])
        #expect(second.texts == ["current"])
        await conn.shutdown()
    }

    @Test func scopedStreamKeepsItsSinkAfterCreationScopeEnds() async throws {
        let conn = MLHostConnection(binaryURL: stubURL(), supportBase: URL(fileURLWithPath: "/tmp"),
            environment: ["STUB_MODE": "scoped-progress"])
        let callAudit = ScopedProgressAudit(), streamAudit = ScopedProgressAudit()
        _ = try await MLProgress.$sink.withValue({ callAudit.append($0) }) {
            try await conn.call(.transcribe(path: "/synthetic.wav", initialPrompt: nil,
                config: .default, safeMode: false, unloadAfter: true))
        }
        let plugin = LocalAIPluginService(connection: conn)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = PrivacyTrace.Context(receiptURL: root.appendingPathComponent("privacy.json"), recordingID: UUID())
        let stream = await PrivacyTrace.$context.withValue(context) {
            await MLProgress.$sink.withValue({ streamAudit.append($0) }) {
                await plugin.analyzeTranscriptStream("Synthetic", outputLanguage: .matchInput)
            }
        }
        var tokens = ""
        for try await token in stream { tokens += token }
        #expect(tokens == "synthetic token")
        #expect(callAudit.texts == ["current"])
        #expect(streamAudit.texts == ["current"])
        await conn.shutdown()
    }
}


extension MLHostConnectionTests {
    @Test func concurrentSameChannelRequestsReceiveOnlyTheirOwnProgress() async throws {
        let conn = MLHostConnection(binaryURL: stubURL(), supportBase: URL(fileURLWithPath: "/tmp"),
            environment: ["STUB_MODE": "interleaved-progress"])
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(10)); await conn.shutdown() } catch { }
        }
        defer { watchdog.cancel() }
        let first = ScopedProgressAudit(), second = ScopedProgressAudit()
        async let a = MLProgress.$sink.withValue({ first.append($0) }) {
            try await conn.call(.transcribe(path: "first", initialPrompt: nil, config: .default, safeMode: false, unloadAfter: true))
        }
        async let b = MLProgress.$sink.withValue({ second.append($0) }) {
            try await conn.call(.transcribe(path: "second", initialPrompt: nil, config: .default, safeMode: false, unloadAfter: true))
        }
        _ = try await (a, b)
        #expect(first.texts == ["first"])
        #expect(second.texts == ["second"])
        await conn.shutdown()
    }

    @Test func proxySafeModeRetryRetainsItsOriginatingProgressSink() async throws {
        let firstFlag = uniqueFlagPath(), crashFlag = uniqueFlagPath()
        defer {
            try? FileManager.default.removeItem(atPath: firstFlag)
            try? FileManager.default.removeItem(atPath: crashFlag)
        }
        let conn = MLHostConnection(binaryURL: stubURL(), supportBase: URL(fileURLWithPath: "/tmp"),
            environment: ["STUB_MODE": "crash-second", "STUB_FLAG_1": firstFlag, "STUB_FLAG_2": crashFlag])
        let plugin = LocalAIPluginService(connection: conn)
        let first = ScopedProgressAudit(), second = ScopedProgressAudit()
        let initial = try await MLProgress.$sink.withValue({ first.append($0) }) {
            try await plugin.transcribe(fileURL: URL(fileURLWithPath: "/synthetic.wav"), initialPrompt: nil, whisperConfig: .default)
        }
        let recovered = try await MLProgress.$sink.withValue({ second.append($0) }) {
            try await plugin.transcribe(fileURL: URL(fileURLWithPath: "/synthetic.wav"), initialPrompt: nil, whisperConfig: .default)
        }
        #expect(initial.text == "echo" && recovered.text == "recovered")
        #expect(first.texts == ["live"])
        #expect(!second.texts.isEmpty && second.texts.allSatisfy { $0 == "live" })
        await conn.shutdown()
    }
}
