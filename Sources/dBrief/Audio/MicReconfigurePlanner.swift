import Foundation

/// Pure, hardware-independent description of how the mic engine should be
/// reconfigured in response to an input-device or output-route change.
struct MicReconfigureDecision: Equatable {
    /// The device UID the engine should be pointed at. Empty string == "System
    /// Default" (pass `nil` to `applyInputDevice` → the engine stays on its bound
    /// default).
    let targetDeviceUID: String
    /// Whether Voice-Processing IO (real-time AEC) should be enabled.
    let voiceProcessingEnabled: Bool
    /// True iff `(targetDeviceUID, voiceProcessingEnabled)` differs from the
    /// state already applied to the engine — i.e. an actual reconfigure is
    /// warranted. When false, the caller no-ops (avoids needless engine churn).
    let needsReconfigure: Bool
}

/// Decides how the mic capture engine should adapt when an audio device or the
/// output route changes mid-recording. Pure — does no CoreAudio I/O; the caller
/// supplies the available device set and the output echo-path state. This keeps
/// the policy unit-testable without hardware.
enum MicReconfigurePlanner {
    /// - Parameters:
    ///   - selectedUID: the user's chosen input UID (`""` == System Default).
    ///   - availableInputUIDs: UIDs of input devices currently present.
    ///   - hasSystemAudioPermission: mixed mode (true) forces VPIO off — it would
    ///     conflict with ScreenCaptureKit, mirroring `startMicPipeline`'s gate.
    ///   - aecSettingEnabled: the raw `AppSettings.acousticEchoCancellation`.
    ///   - outputHasEchoPath: whether the current output route bleeds into the mic
    ///     (`AudioOutputRoute.currentOutputHasEchoPath()`).
    ///   - currentlyAppliedUID: the device the engine is pointed at now (`""` == default).
    ///   - currentlyVoiceProcessing: the VPIO state currently applied.
    static func decide(
        selectedUID: String,
        availableInputUIDs: Set<String>,
        hasSystemAudioPermission: Bool,
        aecSettingEnabled: Bool,
        outputHasEchoPath: Bool,
        currentlyAppliedUID: String,
        currentlyVoiceProcessing: Bool
    ) -> MicReconfigureDecision {
        // Target device: follow the system default when nothing is pinned, keep a
        // pinned device while it's present, and fall back to the default when a
        // pinned device disappears (e.g. AirPods die) so capture never goes silent.
        let targetUID: String
        if selectedUID.isEmpty {
            targetUID = ""
        } else if availableInputUIDs.contains(selectedUID) {
            targetUID = selectedUID
        } else {
            targetUID = ""
        }

        // VPIO only helps when speaker audio bleeds into the mic, and only runs in
        // mic-only mode (it ducks system audio at the OS level, which breaks the
        // ScreenCaptureKit system-audio capture used in mixed mode).
        let voiceProcessing = aecSettingEnabled && outputHasEchoPath && !hasSystemAudioPermission

        let needsReconfigure = targetUID != currentlyAppliedUID
            || voiceProcessing != currentlyVoiceProcessing

        return MicReconfigureDecision(
            targetDeviceUID: targetUID,
            voiceProcessingEnabled: voiceProcessing,
            needsReconfigure: needsReconfigure
        )
    }
}
