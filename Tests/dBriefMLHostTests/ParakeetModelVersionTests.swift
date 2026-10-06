import FluidAudio
import Testing
@testable import dBriefMLHost

struct ParakeetModelVersionTests {
    @Test("Each catalog variant loads its own FluidAudio model; unknown falls back to v3")
    func variantsMapToTheirOwnModel() {
        #expect(ParakeetTranscriptionService.asrVersion(for: "v2") == .v2)
        #expect(ParakeetTranscriptionService.asrVersion(for: "v3") == .v3)
        #expect(ParakeetTranscriptionService.asrVersion(for: "ultra") == .ultra)
        #expect(ParakeetTranscriptionService.asrVersion(for: "obsolete-variant") == .v3)
        #expect(ParakeetTranscriptionService.asrVersion(for: "") == .v3)
    }

    @Test("Redux and Phonon-2 load their own model where the OS supports them, and v3 where it does not")
    func macOS15VariantsFollowOSSupport() {
        let supported: Bool
        if #available(macOS 15, *) { supported = true } else { supported = false }
        #expect(ParakeetTranscriptionService.asrVersion(for: "redux") == (supported ? .redux : .v3))
        #expect(ParakeetTranscriptionService.asrVersion(for: "phonon2") == (supported ? .phonon2 : .v3))
    }
}
