import FluidAudio
import Testing
@testable import dBriefMLHost

struct KokoroVariantTests {
    @Test("Voice id prefixes route to the matching language frontend")
    func voicePrefixSelectsVariant() {
        for voice in ["af_heart", "am_michael", "bf_emma", "bm_george"] {
            #expect(KokoroTTSService.variant(for: voice) == .english)
        }
        #expect(KokoroTTSService.variant(for: "ef_dora") == .spanish)
        #expect(KokoroTTSService.variant(for: "em_alex") == .spanish)
        #expect(KokoroTTSService.variant(for: "ff_siwis") == .french)
        #expect(KokoroTTSService.variant(for: "jf_alpha") == .japanese)
        #expect(KokoroTTSService.variant(for: "jm_kumo") == .japanese)
        #expect(KokoroTTSService.variant(for: "zf_xiaobei") == .mandarin)
    }
}
