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

    @Test("Redux loads Redux where the OS supports it, and v3 where it does not")
    func reduxFollowsOSSupport() {
        let expected: AsrModelVersion
        if #available(macOS 15, *) { expected = .redux } else { expected = .v3 }
        #expect(ParakeetTranscriptionService.asrVersion(for: "redux") == expected)
    }
}
