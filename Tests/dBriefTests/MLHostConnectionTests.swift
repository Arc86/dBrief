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
