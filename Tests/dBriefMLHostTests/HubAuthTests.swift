import Foundation
import Testing
@testable import dBriefMLHost

/// Every model dBrief downloads is public. Left to themselves the Hub clients
/// fall back to `~/.cache/huggingface/token`, and a stale token there makes
/// Hugging Face answer 401 even for public repos — so downloads must opt out.
@Suite("Hugging Face auth")
struct HubAuthTests {
    @Test("The anonymous token is empty, which every Hub client treats as no auth")
    func anonymousTokenIsEmpty() {
        #expect(HubAuth.anonymousToken == "")
    }

    @Test("SpeakerKit downloads ignore the global token")
    func speakerKitIsAnonymous() {
        let config = WhisperKitTranscriptionService.speakerKitConfig(downloadBase: "/tmp/speakerkit")
        #expect(config.modelDownloadConfig.modelToken == HubAuth.anonymousToken)
    }

    @Test("TTSKit downloads ignore the global token")
    func ttsKitIsAnonymous() {
        let config = TTSService.ttsConfig(variant: .qwen3TTS_0_6b, downloadBase: URL(fileURLWithPath: "/tmp/tts"))
        #expect(config.modelToken == HubAuth.anonymousToken)
    }
}
