import Foundation
import Testing
@testable import dBrief

struct CallEndDecisionTests {
    // Convenience wrapper with sensible defaults so each test states only what it varies.
    private func decide(
        action: AppSettings.CallEndAction = .prompt,
        scope: AppSettings.CallEndScope = .callInitiatedOnly,
        isCapturing: Bool = true,
        endedBundleId: String = "us.zoom.xos",
        initiatorBundleId: String? = "us.zoom.xos",
        alreadyPrompting: Bool = false
    ) -> CallEndOutcome {
        CallEndDecision.decide(
            action: action,
            scope: scope,
            isCapturing: isCapturing,
            endedBundleId: endedBundleId,
            initiatorBundleId: initiatorBundleId,
            alreadyPrompting: alreadyPrompting
        )
    }

    @Test
    func offIgnores() {
        #expect(decide(action: .off) == .ignore)
    }

    @Test
    func notCapturingIgnores() {
        #expect(decide(isCapturing: false) == .ignore)
    }

    @Test
    func alreadyPromptingIgnores() {
        #expect(decide(alreadyPrompting: true) == .ignore)
    }

    @Test
    func callInitiatedManualRecordingIgnores() {
        // Manual recording: no initiator, so call-initiated scope never matches.
        #expect(decide(scope: .callInitiatedOnly, initiatorBundleId: nil) == .ignore)
    }

    @Test
    func callInitiatedMismatchedAppIgnores() {
        #expect(decide(
            scope: .callInitiatedOnly,
            endedBundleId: "com.microsoft.teams2",
            initiatorBundleId: "us.zoom.xos"
        ) == .ignore)
    }

    @Test
    func callInitiatedMatchPrompts() {
        #expect(decide(action: .prompt, scope: .callInitiatedOnly) == .prompt)
    }

    @Test
    func callInitiatedMatchAutoStops() {
        #expect(decide(action: .autoStop, scope: .callInitiatedOnly) == .stop)
    }

    @Test
    func anyActiveRecordingActsRegardlessOfInitiator() {
        // No initiator (manual) but scope is any-active → still acts.
        #expect(decide(action: .autoStop, scope: .anyActiveRecording, initiatorBundleId: nil) == .stop)
        // Mismatched initiator also acts under any-active scope.
        #expect(decide(
            action: .prompt,
            scope: .anyActiveRecording,
            endedBundleId: "com.microsoft.teams2",
            initiatorBundleId: "us.zoom.xos"
        ) == .prompt)
    }

    @Test
    func pausedRecordingBehavesLikeRecording() {
        // Callers pass isCapturing = isRecording || isPaused; a paused recording is capturing.
        #expect(decide(action: .autoStop, isCapturing: true) == .stop)
    }
}
