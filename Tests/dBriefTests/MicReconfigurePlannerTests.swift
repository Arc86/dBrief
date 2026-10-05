import Foundation
import Testing
@testable import dBrief

struct MicReconfigurePlannerTests {
    // Convenience wrapper with sensible defaults so each test states only what it varies.
    private func decide(
        selectedUID: String = "",
        available: Set<String> = ["BuiltIn", "Buds"],
        defaultUID: String? = "BuiltIn",
        mixed: Bool = true,
        aec: Bool = true,
        echoPath: Bool = true,
        applied: MicSourcePlan? = nil,
        sourceFailed: Bool = false
    ) -> MicReconfigureDecision {
        MicReconfigurePlanner.decide(
            selectedUID: selectedUID,
            availableInputUIDs: available,
            defaultInputUID: defaultUID,
            hasSystemAudioPermission: mixed,
            aecSettingEnabled: aec,
            outputHasEchoPath: echoPath,
            applied: applied,
            sourceFailed: sourceFailed
        )
    }

    private func engine(_ uid: String, vpio: Bool = false) -> MicSourcePlan {
        MicSourcePlan(deviceUID: uid, backend: .engine, voiceProcessing: vpio)
    }

    private func session(_ uid: String) -> MicSourcePlan {
        MicSourcePlan(deviceUID: uid, backend: .captureSession, voiceProcessing: false)
    }

    // MARK: Device and backend choice

    @Test
    func systemDefaultUsesEngineOnTheDefaultDevice() {
        #expect(decide().plan == engine("BuiltIn"))
    }

    @Test
    func pinnedDefaultDeviceUsesEngine() {
        #expect(decide(selectedUID: "BuiltIn").plan == engine("BuiltIn"))
    }

    @Test
    func pinnedOffDefaultDeviceUsesCaptureSession() {
        // Buds are the macOS default; the user picks the built-in mic in dBrief.
        // AVAudioEngine delivers zero callbacks for that route.
        #expect(decide(selectedUID: "BuiltIn", defaultUID: "Buds").plan == session("BuiltIn"))
    }

    @Test
    func pinnedGoneFallsBackToDefaultEngine() {
        let d = decide(selectedUID: "Buds", available: ["BuiltIn"], applied: session("Buds"))
        #expect(d.plan == engine("BuiltIn"))
        #expect(d.needsReconfigure)
    }

    @Test
    func pinnedDeviceReturnsWhenReconnected() {
        let d = decide(selectedUID: "Buds", applied: engine("BuiltIn"))
        #expect(d.plan == session("Buds"))
        #expect(d.needsReconfigure)
    }

    @Test
    func noInputDeviceKeepsTheCurrentSource() {
        let d = decide(available: [], defaultUID: nil, applied: engine("BuiltIn"))
        #expect(d.plan == nil)
        #expect(!d.needsReconfigure)
    }

    // MARK: Following the system default

    @Test
    func systemDefaultChangeBuildsANewSourceForTheNewDevice() {
        // Buds connect and become the default mid-recording.
        let d = decide(defaultUID: "Buds", applied: engine("BuiltIn"))
        #expect(d.plan == engine("Buds"))
        #expect(d.needsReconfigure)
    }

    @Test
    func pinnedDeviceMovesToCaptureSessionWhenItStopsBeingDefault() {
        let d = decide(selectedUID: "BuiltIn", defaultUID: "Buds", applied: engine("BuiltIn"))
        #expect(d.plan == session("BuiltIn"))
        #expect(d.needsReconfigure)
    }

    @Test
    func stableStateIsANoOp() {
        #expect(!decide(applied: engine("BuiltIn")).needsReconfigure)
        #expect(!decide(selectedUID: "Buds", applied: session("Buds")).needsReconfigure)
    }

    @Test
    func failedSourceRebuildsEvenWhenThePlanIsUnchanged() {
        #expect(decide(applied: engine("BuiltIn"), sourceFailed: true).needsReconfigure)
    }

    // MARK: Voice processing

    @Test
    func mixedModeNeverUsesVoiceProcessing() {
        #expect(decide(mixed: true).plan?.voiceProcessing == false)
    }

    @Test
    func micOnlyOnSpeakersUsesVoiceProcessing() {
        #expect(decide(mixed: false).plan == engine("BuiltIn", vpio: true))
    }

    @Test
    func headphonesTurnVoiceProcessingOff() {
        let d = decide(mixed: false, echoPath: false, applied: engine("BuiltIn", vpio: true))
        #expect(d.plan == engine("BuiltIn"))
        #expect(d.needsReconfigure)
    }

    @Test
    func aecSettingOffKeepsVoiceProcessingOff() {
        #expect(decide(mixed: false, aec: false).plan == engine("BuiltIn"))
    }

    @Test
    func captureSessionNeverClaimsVoiceProcessing() {
        let d = decide(selectedUID: "BuiltIn", defaultUID: "Buds", mixed: false)
        #expect(d.plan == session("BuiltIn"))
    }

    // MARK: Fallback after a source delivers no audio

    @Test
    func silentEngineFallsBackToCaptureSessionOnTheSameDevice() {
        #expect(MicReconfigurePlanner.fallback(after: engine("Buds", vpio: true), defaultInputUID: "Buds")
            == session("Buds"))
    }

    @Test
    func silentPinnedSessionFallsBackToTheDefaultEngine() {
        #expect(MicReconfigurePlanner.fallback(after: session("BuiltIn"), defaultInputUID: "Buds")
            == engine("Buds"))
    }

    @Test
    func silentSessionOnTheDefaultHasNoFurtherFallback() {
        #expect(MicReconfigurePlanner.fallback(after: session("Buds"), defaultInputUID: "Buds") == nil)
        #expect(MicReconfigurePlanner.fallback(after: session("Buds"), defaultInputUID: nil) == nil)
    }
}
