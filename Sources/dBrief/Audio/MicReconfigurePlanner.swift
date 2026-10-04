import Foundation

/// How a microphone is captured.
enum MicBackend: Equatable, Sendable {
    /// AVAudioEngine input node. Captures only the macOS default input: binding
    /// its HAL unit to any other device delivers zero callbacks on current macOS
    /// (docs/diagnostics/2026-09-20-audio-switching-review.md). The only backend
    /// with Voice-Processing IO (real-time AEC).
    case engine
    /// AVCaptureSession for an exact device UID. Used for a microphone that is
    /// not the macOS default (2026-09-21 capture-session probe: both directions
    /// between Bluetooth and built-in, plus pause/resume).
    case captureSession
}

/// The microphone source that should be running: a concrete device (never the
/// "System Default" placeholder), how it is captured, and whether VPIO is on.
struct MicSourcePlan: Equatable, Sendable {
    let deviceUID: String
    let backend: MicBackend
    let voiceProcessing: Bool
}

/// Pure, hardware-independent description of how the mic source should change
/// in response to a selection, input-device or output-route change.
struct MicReconfigureDecision: Equatable {
    /// `nil` when no input device is available; the caller keeps what it has.
    let plan: MicSourcePlan?
    /// True iff `plan` differs from the running source, or that source failed.
    let needsReconfigure: Bool
}

/// Decides which mic source should run. Pure — does no CoreAudio I/O; the
/// caller supplies the device set, default device and output echo-path state.
enum MicReconfigurePlanner {
    /// - Parameters:
    ///   - selectedUID: the user's chosen input UID (`""` == System Default).
    ///   - availableInputUIDs: UIDs of input devices currently present.
    ///   - defaultInputUID: UID of the current macOS default input, if any.
    ///   - hasSystemAudioPermission: mixed mode (true) forces VPIO off — it ducks
    ///     system audio at the OS level, which breaks ScreenCaptureKit capture.
    ///   - aecSettingEnabled: the raw `AppSettings.acousticEchoCancellation`.
    ///   - outputHasEchoPath: whether the current output route bleeds into the mic.
    ///   - applied: the source currently running, if any.
    ///   - sourceFailed: the running source stopped or stopped delivering audio.
    static func decide(
        selectedUID: String,
        availableInputUIDs: Set<String>,
        defaultInputUID: String?,
        hasSystemAudioPermission: Bool,
        aecSettingEnabled: Bool,
        outputHasEchoPath: Bool,
        applied: MicSourcePlan?,
        sourceFailed: Bool = false
    ) -> MicReconfigureDecision {
        // Follow the system default when nothing is pinned, keep a pinned device
        // while it's present, and fall back to the default when a pinned device
        // disappears (e.g. AirPods die) so capture never goes silent.
        let target = !selectedUID.isEmpty && availableInputUIDs.contains(selectedUID)
            ? selectedUID : defaultInputUID
        guard let target, !target.isEmpty else {
            return MicReconfigureDecision(plan: nil, needsReconfigure: false)
        }

        let backend: MicBackend = target == defaultInputUID ? .engine : .captureSession
        // VPIO only helps when speaker audio bleeds into the mic, only runs in
        // mic-only mode, and only exists on the engine backend.
        let voiceProcessing = backend == .engine
            && aecSettingEnabled && outputHasEchoPath && !hasSystemAudioPermission

        let plan = MicSourcePlan(deviceUID: target, backend: backend, voiceProcessing: voiceProcessing)
        return MicReconfigureDecision(plan: plan, needsReconfigure: plan != applied || sourceFailed)
    }

    /// The one alternative to try when `failed` started but delivered no audio.
    /// An engine retries the same device through a capture session (giving up
    /// VPIO); a pinned capture session falls back to the default device's engine.
    static func fallback(after failed: MicSourcePlan, defaultInputUID: String?) -> MicSourcePlan? {
        switch failed.backend {
        case .engine:
            return MicSourcePlan(deviceUID: failed.deviceUID, backend: .captureSession, voiceProcessing: false)
        case .captureSession:
            guard let defaultInputUID, !defaultInputUID.isEmpty, defaultInputUID != failed.deviceUID else {
                return nil
            }
            return MicSourcePlan(deviceUID: defaultInputUID, backend: .engine, voiceProcessing: false)
        }
    }
}
