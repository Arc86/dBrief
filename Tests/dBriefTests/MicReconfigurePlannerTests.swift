import Foundation
import Testing
@testable import dBrief

struct MicReconfigurePlannerTests {
    // Convenience wrapper with sensible defaults so each test states only what it varies.
    private func decide(
        selectedUID: String = "",
        available: Set<String> = [],
        mixed: Bool = false,
        aec: Bool = true,
        echoPath: Bool = true,
        appliedUID: String = "",
        appliedVPIO: Bool = false
    ) -> MicReconfigureDecision {
        MicReconfigurePlanner.decide(
            selectedUID: selectedUID,
            availableInputUIDs: available,
            hasSystemAudioPermission: mixed,
            aecSettingEnabled: aec,
            outputHasEchoPath: echoPath,
            currentlyAppliedUID: appliedUID,
            currentlyVoiceProcessing: appliedVPIO
        )
    }

    @Test
    func pinnedPresentStays() {
        let d = decide(selectedUID: "HS", available: ["HS", "BuiltIn"], mixed: true, appliedUID: "HS")
        #expect(d.targetDeviceUID == "HS")
        #expect(!d.needsReconfigure)
    }

    @Test
    func pinnedGoneFallsBackToDefault() {
        // AirPods pinned but no longer present → fall back to default, keep recording.
        let d = decide(selectedUID: "AirPods", available: ["BuiltIn"], mixed: true, appliedUID: "AirPods")
        #expect(d.targetDeviceUID == "")
        #expect(d.needsReconfigure)
    }

    @Test
    func systemDefaultFollowsAndNoOpWhenStable() {
        // Empty selection, already on default, mixed mode (no VPIO) → nothing to do.
        let d = decide(selectedUID: "", available: ["BuiltIn"], mixed: true, appliedUID: "")
        #expect(d.targetDeviceUID == "")
        #expect(!d.needsReconfigure)
    }

    @Test
    func speakersToHeadphonesTogglesVPIOOff() {
        // Mic-only, AEC on, output now has no echo path, VPIO currently on → turn off.
        let d = decide(mixed: false, aec: true, echoPath: false, appliedVPIO: true)
        #expect(!d.voiceProcessingEnabled)
        #expect(d.needsReconfigure)
    }

    @Test
    func headphonesToSpeakersTogglesVPIOOn() {
        let d = decide(mixed: false, aec: true, echoPath: true, appliedVPIO: false)
        #expect(d.voiceProcessingEnabled)
        #expect(d.needsReconfigure)
    }

    @Test
    func mixedModeNeverTogglesVPIO() {
        // Even with AEC on and an echo path, mixed mode keeps VPIO off.
        let d = decide(mixed: true, aec: true, echoPath: true, appliedVPIO: false)
        #expect(!d.voiceProcessingEnabled)
        #expect(!d.needsReconfigure)
    }

    @Test
    func idempotentNoOp() {
        // Desired equals applied (pinned present + VPIO already on) → no reconfigure.
        let d = decide(selectedUID: "HS", available: ["HS"], mixed: false, aec: true, echoPath: true,
                       appliedUID: "HS", appliedVPIO: true)
        #expect(!d.needsReconfigure)
    }

    @Test
    func aecSettingOffKeepsVPIOOff() {
        let d = decide(mixed: false, aec: false, echoPath: true, appliedVPIO: false)
        #expect(!d.voiceProcessingEnabled)
        #expect(!d.needsReconfigure)
    }

    @Test
    func deviceGoneAndVPIOChangeBothApply() {
        // Pinned device vanished AND route changed at once (the AirPods-die storm).
        let d = decide(selectedUID: "AirPods", available: ["BuiltIn"], mixed: false,
                       aec: true, echoPath: true, appliedUID: "AirPods", appliedVPIO: false)
        #expect(d.targetDeviceUID == "")
        #expect(d.voiceProcessingEnabled)
        #expect(d.needsReconfigure)
    }
}
