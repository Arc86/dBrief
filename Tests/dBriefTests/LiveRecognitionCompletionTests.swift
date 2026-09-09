import Foundation
import Testing
@testable import dBrief

@Suite("Live recognition terminal acknowledgment") @MainActor
struct LiveRecognitionCompletionTests {
    @MainActor private final class Probe {
        var outcomes: [PrivacyAttempt.Outcome] = []
        var cancellations = 0
        var persistence: CheckedContinuation<Void, Never>?
        func persist(_ outcome: PrivacyAttempt.Outcome) async {
            outcomes.append(outcome)
            await withCheckedContinuation { persistence = $0 }
        }
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }
    @Test(arguments: [false, true])
    func cancellationWaitsForNativeAcknowledgmentAndPersistence(finalObservedFirst: Bool) async throws {
        let probe = Probe()
        let gate = LiveRecognitionCompletion(completion: .init(persist: { await probe.persist($0) }))
        gate.installCancellation { Task { @MainActor in probe.cancellations += 1 } }
        if finalObservedFirst { gate.observe(.succeeded) }
        gate.requestCancellation()
        gate.requestCancellation()
        var returned = 0
        let one = Task { await gate.wait(); returned += 1 }
        let two = Task { await gate.wait(); returned += 1 }
        try await wait { probe.cancellations == 1 && probe.persistence != nil }
        #expect(returned == 0)
        gate.acknowledge(.cancelled)
        gate.acknowledge(.failed)
        await Task.yield()
        #expect(returned == 0)
        probe.persistence?.resume(); probe.persistence = nil
        await one.value; await two.value
        #expect(returned == 2)
        #expect(probe.outcomes == [finalObservedFirst ? .succeeded : .cancelled])
    }

    @Test func cancellationBeforeNativeHandleInstallationIsDeliveredOnceAndStillNeedsAcknowledgment() async throws {
        let probe = Probe()
        let gate = LiveRecognitionCompletion(completion: .init(persist: { _ in }))
        gate.requestCancellation()
        gate.installCancellation { Task { @MainActor in probe.cancellations += 1 } }
        try await wait { probe.cancellations == 1 }
        var returned = false
        let task = Task { await gate.wait(); returned = true }
        await Task.yield()
        #expect(!returned)
        gate.acknowledge(.cancelled)
        await task.value
        gate.installCancellation { Issue.record("Completed native handle was retained or cancelled again") }
        gate.requestCancellation()
        #expect(returned && probe.cancellations == 1)
    }
}
