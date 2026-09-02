import Foundation
import Testing
@testable import dBrief

@Suite("FFmpeg process runner")
struct FFmpegProcessRunnerTests {
    @Test("Drains output larger than pipe capacity and retains only bounded tails")
    func drainsLargeStdoutAndStderr() async throws {
        let runner = FFmpegProcessRunner(configuration: .init(
            retainedBytesPerPipe: 4_096,
            stallTimeout: 5,
            watchdogInterval: 0.05,
            terminationGracePeriod: 0.1
        ))

        let result = try await runner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "head -c 131072 /dev/zero; printf done; head -c 196608 /dev/zero >&2",
            ],
            monitorProgress: false
        )

        #expect(result.exitStatus == 0)
        #expect(result.stdoutByteCount == 131_076)
        #expect(result.stderrByteCount == 196_608)
        #expect(result.stdoutTail.count <= 4_096)
        #expect(result.stderrTail.count <= 4_096)
        #expect(result.stdout.hasSuffix("done"))
    }

    @Test("A stalled process is terminated and a subsequent job can run")
    func stallDoesNotBlockLaterJobs() async throws {
        let runner = FFmpegProcessRunner(configuration: .init(
            retainedBytesPerPipe: 1_024,
            stallTimeout: 0.2,
            watchdogInterval: 0.05,
            terminationGracePeriod: 0.1
        ))

        do {
            _ = try await runner.run(
                executable: "/bin/sleep",
                arguments: ["10"],
                monitorProgress: true
            )
            Issue.record("Expected the inactive process to be stopped")
        } catch let error as ProcessRunError {
            guard case .stalled = error else {
                Issue.record("Expected stalled, got \(error)")
                return
            }
        }

        let result = try await runner.run(
            executable: "/bin/echo",
            arguments: ["next-job"],
            monitorProgress: true
        )
        #expect(result.exitStatus == 0)
        #expect(result.stdout == "next-job\n")
    }

    @Test("Task cancellation terminates the child process")
    func cancellationTerminatesChild() async throws {
        let runner = FFmpegProcessRunner(configuration: .init(
            retainedBytesPerPipe: 1_024,
            stallTimeout: 30,
            watchdogInterval: 0.05,
            terminationGracePeriod: 0.1
        ))
        let run = Task {
            try await runner.run(
                executable: "/bin/sleep",
                arguments: ["10"],
                monitorProgress: true
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        run.cancel()

        do {
            _ = try await run.value
            Issue.record("Expected cancellation to stop the process")
        } catch let error as ProcessRunError {
            guard case .cancelled = error else {
                Issue.record("Expected cancelled, got \(error)")
                return
            }
        }
    }
}
