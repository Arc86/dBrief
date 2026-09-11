import Testing
import CoreAudio
@testable import dBrief

struct AudioInputSelectionTests {
    @Test func systemDefaultResolvesConcreteDeviceInsteadOfLeavingPinnedDevice() throws {
        #expect(try AudioInputDeviceManager.resolveInputDeviceID(uid: nil,
            defaultDevice: { 42 }, deviceForUID: { _ in 99 }) == 42)
        #expect(try AudioInputDeviceManager.resolveInputDeviceID(uid: "  ",
            defaultDevice: { 42 }, deviceForUID: { _ in 99 }) == 42)
    }
    @Test func disconnectedPinnedDeviceFallsBackToCurrentDefault() throws {
        #expect(try AudioInputDeviceManager.resolveInputDeviceID(uid: "earbuds",
            defaultDevice: { 42 }, deviceForUID: { _ in nil }) == 42)
    }
    @Test func presentPinnedDeviceIsSelected() throws {
        #expect(try AudioInputDeviceManager.resolveInputDeviceID(uid: "earbuds",
            defaultDevice: { 42 }, deviceForUID: { _ in 99 }) == 99)
    }
    @Test func unavailableDefaultThrows() {
        #expect(throws: AudioInputDeviceError.self) {
            try AudioInputDeviceManager.resolveInputDeviceID(uid: nil,
                defaultDevice: { nil }, deviceForUID: { _ in nil })
        }
    }
    @Test func stoppedEngineRestartsEvenWhenSelectionIsUnchanged() {
        let decision = MicReconfigurePlanner.decide(selectedUID: "", availableInputUIDs: [],
            hasSystemAudioPermission: true, aecSettingEnabled: false, outputHasEchoPath: false,
            currentlyAppliedUID: "", currentlyVoiceProcessing: false, engineStopped: true)
        #expect(decision.needsReconfigure)
    }
    @Test func systemDefaultHardwareChangeRebindsEngine() {
        let decision = MicReconfigurePlanner.decide(selectedUID: "", availableInputUIDs: [],
            hasSystemAudioPermission: true, aecSettingEnabled: false, outputHasEchoPath: false,
            currentlyAppliedUID: "", currentlyVoiceProcessing: false, defaultInputChanged: true)
        #expect(decision.needsReconfigure)
    }

}
