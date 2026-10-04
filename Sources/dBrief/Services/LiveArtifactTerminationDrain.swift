import Foundation

enum LiveArtifactTerminationResult: Equatable, Sendable {
    case complete, failed, timedOut
}

/// One deadline covers the fixed census after hardware closure. Unstructured
/// work retains its exact pins/leases until actual return after a timeout.
enum LiveArtifactTerminationDrain {
    @MainActor static func run(registry: LiveRecordingSessionRegistry, deadline: Duration) async -> LiveArtifactTerminationResult {
        let frozen = registry.freezeForTermination()
        let (completion, signal) = AsyncStream<LiveArtifactTerminationResult>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let actualWork = Task { @MainActor in
            var complete = true
            for target in frozen.owners {
                if !(await target.waitForActualReturn()) { complete = false }
            }
            for load in frozen.loads {
                // Invalidated late hydration cannot install across the census.
                _ = try? await load.value; complete = false
            }
            signal.yield(complete ? .complete : .failed); signal.finish()
        }
        let timer = Task {
            do { try await Task.sleep(for: max(.zero, min(.seconds(3), deadline))) }
            catch { return }
            signal.yield(.timedOut); signal.finish()
        }
        var outcome = LiveArtifactTerminationResult.timedOut
        for await result in completion { outcome = result; break }
        timer.cancel()
        if outcome == .timedOut { for target in frozen.owners { target.recordTimeoutIfIncomplete() } }
        // Do not cancel or await the loser: the task owns every frozen target
        // through actual return, including cancellation-ignoring physical IO.
        withExtendedLifetime(actualWork) {}
        return outcome
    }
}
