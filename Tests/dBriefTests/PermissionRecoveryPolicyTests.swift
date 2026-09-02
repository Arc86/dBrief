import Testing
@testable import dBrief

@Suite("Permission recovery policy")
struct PermissionRecoveryPolicyTests {
    @Test
    func deniedPermissionRoutesToSystemSettings() {
        #expect(PermissionRecoveryPolicy.action(for: .denied) == .openSystemSettings)
        #expect(!PermissionRecoveryPolicy.canContinue(requiredState: .denied))
    }

    @Test
    func undeterminedPermissionRequestsAccess() {
        #expect(PermissionRecoveryPolicy.action(for: .notDetermined) == .requestAccess)
    }

    @Test
    func restrictedPermissionDoesNotOfferAnImpossiblePrompt() {
        #expect(PermissionRecoveryPolicy.action(for: .restricted) == .explainRestriction)
    }

    @Test
    func grantedPermissionNeedsNoRecoveryAndCanContinue() {
        #expect(PermissionRecoveryPolicy.action(for: .granted) == .none)
        #expect(PermissionRecoveryPolicy.canContinue(requiredState: .granted))
    }

    @Test
    func eitherAudioSourceCanSatisfyOnboarding() {
        #expect(PermissionRecoveryPolicy.canContinue(audioSourceStates: [.granted, .denied]))
        #expect(PermissionRecoveryPolicy.canContinue(audioSourceStates: [.denied, .granted]))
        #expect(!PermissionRecoveryPolicy.canContinue(audioSourceStates: [.denied, .notDetermined]))
    }
}
