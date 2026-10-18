import Testing
@testable import dBrief

struct SpeakerIdentificationSupportTests {
    @Test func onDeviceEnginesWithDiarizationAreSupported() {
        #expect(SpeakerIdentificationSupport.isSupported(engine: .localWhisper, remoteProvider: nil))
        #expect(SpeakerIdentificationSupport.isSupported(engine: .parakeetLocal, remoteProvider: nil))
        #expect(!SpeakerIdentificationSupport.isSupported(engine: .appleSpeech, remoteProvider: nil))
    }

    @Test func onlyRemoteProvidersThatDiarizeAreSupported() {
        #expect(SpeakerIdentificationSupport.isSupported(engine: .remoteEndpoint, remoteProvider: .deepgram))
        #expect(SpeakerIdentificationSupport.isSupported(engine: .remoteEndpoint, remoteProvider: .elevenLabs))
        #expect(!SpeakerIdentificationSupport.isSupported(engine: .remoteEndpoint, remoteProvider: .openAICompatible))
        #expect(!SpeakerIdentificationSupport.isSupported(engine: .remoteEndpoint, remoteProvider: nil))
    }
}
