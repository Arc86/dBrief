import Foundation

/// Outcome of evaluating a "call ended" event against the user's settings and current state.
enum CallEndOutcome: Equatable {
    case ignore   // do nothing
    case stop     // stop the recording automatically
    case prompt   // ask the user whether to stop
}

/// Pure, dependency-free decision for what to do when a call ends. Kept separate from
/// `CallDetectionService` so it can be unit-tested without CoreAudio or `@MainActor`
/// (mirrors `MicReconfigurePlanner`).
enum CallEndDecision {
    /// - Parameters:
    ///   - action: the configured `.off` / `.prompt` / `.autoStop` behavior.
    ///   - scope: whether to act only on call-initiated recordings or any active recording.
    ///   - isCapturing: whether a recording is currently active (recording or paused).
    ///   - endedBundleId: bundle id of the call app whose meeting just ended.
    ///   - initiatorBundleId: bundle id of the call app that started the current recording,
    ///     or `nil` if the recording was started manually.
    ///   - alreadyPrompting: whether a "call ended" prompt is already on screen.
    static func decide(
        action: AppSettings.CallEndAction,
        scope: AppSettings.CallEndScope,
        isCapturing: Bool,
        endedBundleId: String,
        initiatorBundleId: String?,
        alreadyPrompting: Bool
    ) -> CallEndOutcome {
        guard action != .off, isCapturing, !alreadyPrompting else { return .ignore }

        if scope == .callInitiatedOnly {
            guard let initiatorBundleId, initiatorBundleId == endedBundleId else { return .ignore }
        }

        return action == .autoStop ? .stop : .prompt
    }
}
