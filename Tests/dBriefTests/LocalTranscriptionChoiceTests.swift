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

    @Test func everyParakeetVariantRoundTripsThroughItsPickerID() {
        for model in ParakeetModelInfo.available {
            let id = LocalTranscriptionChoice.id(engine: .parakeetLocal, whisper: "custom-whisper", parakeet: model.id)
            #expect(id == LocalTranscriptionChoice.parakeet(model.id))
            #expect(LocalTranscriptionChoice.engine(id) == .parakeetLocal)
            #expect(LocalTranscriptionChoice.parakeetVariant(id) == model.id)
            #expect(LocalTranscriptionChoice.title(id) == model.displayName)
            #expect(LocalTranscriptionChoice.extraIDs.contains(id))
        }
        // A stale or unsupported saved variant still routes to Parakeet, resolved to the default.
        #expect(LocalTranscriptionChoice.engine("parakeet:obsolete") == .parakeetLocal)
        #expect(LocalTranscriptionChoice.parakeetVariant("parakeet:obsolete") == ParakeetModelInfo.defaultID)
        #expect(LocalTranscriptionChoice.parakeetVariant("custom-whisper") == nil)
        #expect(LocalTranscriptionChoice.parakeetVariant(LocalTranscriptionChoice.apple) == nil)
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
        for model in ParakeetModelInfo.available {
            let id = LocalTranscriptionChoice.parakeet(model.id)
            #expect(TranscriptionCardPresentation.local(id)?.accuracy == 4)
            // Redux trades speed for size (~34% slower than v3 on the ANE upstream).
            #expect(TranscriptionCardPresentation.local(id)?.speed == (model.id == "redux" ? 4 : 5))
            #expect(TranscriptionCardPresentation.local(id)?.language == (model.isEnglishOnly ? "English only" : "25 European languages"))
            #expect(LocalTranscriptionChoice.runtimeGiB(id) == Double(model.estimatedMemoryMB) / 1024)
        }
        #expect(TranscriptionCardPresentation.local("unknown") == nil)
        #expect(LocalTranscriptionChoice.runtimeGiB("unknown") == nil)
    }
}
