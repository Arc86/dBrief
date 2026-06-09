import Testing
import Foundation
import dBriefWire
@testable import dBrief

private struct TimeoutError: Error {}

private actor StateCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}

/// A unique temp-file path for a stub's cross-restart crash flag, so tests that
/// run in parallel never race over a shared file.
func uniqueFlagPath() -> String {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("stub-\(ProcessInfo.processInfo.globallyUniqueString)")
        .path
}

/// Runs `op`, failing with `TimeoutError` if it does not finish in `seconds`.
/// Lets a hung await surface as a test failure instead of stalling the suite.
private func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

@Suite struct TranscribeRetryTests {
    @Test func retriesOnceAfterCrashThenSucceeds() async throws {
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "crash-once", "STUB_FLAG_1": uniqueFlagPath()])
        let svc = LocalAIPluginService(connection: conn)
        let result = try await svc.transcribe(fileURL: URL(fileURLWithPath: "/a.m4a"),
                                               initialPrompt: nil, whisperConfig: .default)
        #expect(result.text == "recovered")   // first call crashed, retry returned this
        await conn.shutdown()
    }

    /// Reproduces the field hang: a successful first transcription followed by a
    /// second that crashes once and recovers in safe mode — while a per-op task
    /// consumes the shared `stateStream` each time (as `withPluginStepAdapter`
    /// does). The retry result must still come back; if it hangs, the UI step
    /// never completes (recordingState stuck on `.processing`).
    @Test func secondOpCrashesAndStillReturnsWhileConsumingStateStream() async throws {
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "crash-second",
                                                  "STUB_FLAG_1": uniqueFlagPath(),
                                                  "STUB_FLAG_2": uniqueFlagPath()])
        let svc = LocalAIPluginService(connection: conn)

        // One transcribe op with a concurrent state-stream consumer, cancelled
        // after the op — mirrors RecordingManager.withPluginStepAdapter.
        let counter = StateCounter()
        let runOp: @Sendable () async throws -> String = {
            let stateTask = Task { for await _ in svc.stateStream { await counter.bump() } }
            defer { stateTask.cancel() }
            let text = try await svc.transcribe(fileURL: URL(fileURLWithPath: "/a.m4a"),
                                                initialPrompt: nil, whisperConfig: .default).text
            try? await Task.sleep(nanoseconds: 200_000_000)  // let trailing state frames drain
            return text
        }

        let first = try await withTimeout(seconds: 20) { try await runOp() }
        #expect(first == "echo")
        let afterFirst = await counter.value
        #expect(afterFirst >= 1)         // op #1 delivered live state(s)

        let second = try await withTimeout(seconds: 20) { try await runOp() }
        #expect(second == "recovered")   // hangs (→ timeout) if the retry reply never lands
        let afterSecond = await counter.value
        #expect(afterSecond > afterFirst)  // op #2 must ALSO deliver live state(s)
        await conn.shutdown()
    }

    @Test func secondCrashSurfacesCleanError() async {
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "crash-always"])
        await #expect(throws: MLHostError.helperCrashed) {
            _ = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false))
        }
        await conn.shutdown()
    }
}
