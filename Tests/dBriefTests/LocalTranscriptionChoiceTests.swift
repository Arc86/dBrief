import Testing
import dBriefWire
@testable import dBrief

struct LocalTranscriptionChoiceTests {
    @Test func selectionRoutesWithoutMixingIdentifiers() {
        #expect(LocalTranscriptionChoice.engine("apple-speech") == .appleSpeech)
        #expect(LocalTranscriptionChoice.engine("parakeet:v2") == .parakeetLocal)
        #expect(LocalTranscriptionChoice.engine("parakeet:v3") == .parakeetLocal)
        #expect(LocalTranscriptionChoice.engine("custom-whisper") == .localWhisper)
        for (engine, variant, expected) in [
            (AppSettings.TranscriptionEngine.appleSpeech, "v3", "apple-speech"),
            (.parakeetLocal, "v2", "parakeet:v2"),
            (.parakeetLocal, "v3", "parakeet:v3"),
            (.localWhisper, "v3", "custom-whisper")
        ] {
            #expect(LocalTranscriptionChoice.id(engine: engine, whisper: "custom-whisper", parakeet: variant) == expected)
        }
        #expect(Set(LocalTranscriptionChoice.extraIDs).isDisjoint(with: Set(WhisperModelInfo.fallbackModelNames)))
    }

    @Test func appleFallbackHasNoInventedScore() {
        let fallback = TranscriptionCardPresentation.local(LocalTranscriptionChoice.apple)
        #expect(fallback?.accuracy == nil)
        #expect(fallback?.speed == nil)
        let modern = TranscriptionCardPresentation.local(LocalTranscriptionChoice.apple, modernApple: true)
        #expect(modern?.accuracy == 4)
        #expect(modern?.speed == 4)
        #expect(LocalTranscriptionChoice.runtimeGiB(LocalTranscriptionChoice.apple) == nil)
    }

    @Test func parakeetGuidanceAndUnknownFallback() {
        for id in [LocalTranscriptionChoice.parakeetV2, LocalTranscriptionChoice.parakeetV3] {
            #expect(TranscriptionCardPresentation.local(id)?.accuracy == 4)
            #expect(TranscriptionCardPresentation.local(id)?.speed == 5)
            #expect(LocalTranscriptionChoice.runtimeGiB(id) != nil)
        }
        #expect(TranscriptionCardPresentation.local("unknown") == nil)
        #expect(LocalTranscriptionChoice.runtimeGiB("unknown") == nil)
    }
}
