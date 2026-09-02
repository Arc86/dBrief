/// App-domain permission states, kept independent of AVFoundation so onboarding
/// decisions can be covered by fast unit tests.
enum PermissionAuthorizationState: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case granted

    var isGranted: Bool { self == .granted }
}

enum PermissionRecoveryAction: Equatable, Sendable {
    case requestAccess
    case openSystemSettings
    case explainRestriction
    case none
}

enum PermissionRecoveryPolicy {
    static func action(for state: PermissionAuthorizationState) -> PermissionRecoveryAction {
        switch state {
        case .notDetermined: .requestAccess
        case .denied: .openSystemSettings
        case .restricted: .explainRestriction
        case .granted: .none
        }
    }

    static func canContinue(requiredState: PermissionAuthorizationState) -> Bool {
        requiredState == .granted
    }

    /// Recording supports microphone-only, system-audio-only, and mixed mode.
    /// Onboarding therefore needs at least one usable audio source, not a
    /// microphone specifically.
    static func canContinue(audioSourceStates: [PermissionAuthorizationState]) -> Bool {
        audioSourceStates.contains(.granted)
    }
}
