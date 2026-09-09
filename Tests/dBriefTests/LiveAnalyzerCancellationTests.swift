import Foundation
import Testing
@testable import dBrief

@Suite("Live analyzer native cancellation") @MainActor
struct LiveAnalyzerCancellationTests {
    @MainActor private final class Native {
        var calls: [String] = []
        var operation: CheckedContinuation<Void, Never>?
        var cleanup: CheckedContinuation<Void, Never>?
        func run(_ stage: String) async {
            calls.append(stage)
            await withCheckedContinuation { operation = $0 }
            calls.append("operation-returned")
        }
        func cancel() async {
            calls.append("cancel-native")
            operation?.resume(); operation = nil
            await withCheckedContinuation { cleanup = $0 }
            calls.append("cleanup-finished")
        }
        func release() { cleanup?.resume(); cleanup = nil }
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test(arguments: ["start", "finalize"])
    func taskCancellationInvokesNativeCancelWhileOperationIsSuspendedAndJoinsCleanup(stage: String) async throws {
        let native = Native()
        let lifetime = LiveAnalyzerCancellation(cancel: { await native.cancel() })
        var returned = false
        let task = Task {
            defer { returned = true }
            try await lifetime.run { await native.run(stage) }
        }
        try await wait { native.operation != nil }
        task.cancel()
        try await wait { native.cleanup != nil && native.calls.contains("operation-returned") }
        #expect(!returned)
        #expect(native.calls.filter { $0 == "cancel-native" }.count == 1)
        task.cancel()
        native.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(returned && native.calls.last == "cleanup-finished")
        #expect(native.calls.filter { $0 == "cancel-native" }.count == 1)
    }

    @Test func ordinaryErrorAlsoWaitsForCleanupAndRetainsItsError() async throws {
        let native = Native(), lifetime = LiveAnalyzerCancellation(cancel: { await native.cancel() })
        var returned = false
        let task = Task {
            defer { returned = true }
            try await lifetime.run { throw CocoaError(.fileReadUnknown) }
        }
        try await wait { native.cleanup != nil }
        #expect(!returned)
        native.release()
        await #expect(throws: CocoaError.self) { try await task.value }
        #expect(returned)
    }

    @Test func successfulDrainDoesNotCancelNativeAnalyzer() async throws {
        let lifetime = LiveAnalyzerCancellation(cancel: { Issue.record("Successful analyzer was cancelled") })
        let task = Task { try await lifetime.run {} }
        try await task.value
        task.cancel()
        await Task.yield()
    }
}
