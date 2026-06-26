import Testing
import Foundation
@testable import dBriefWire

@Suite struct WireEnvelopeTests {
    @Test func requestRoundTrips() throws {
        let req = RequestEnvelope(
            id: UUID(),
            request: .transcribe(path: "/tmp/a.m4a", initialPrompt: "hi",
                                 config: .default, safeMode: false)
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RequestEnvelope.self, from: data)
        #expect(decoded.id == req.id)
        if case let .transcribe(path, prompt, _, safe) = decoded.request {
            #expect(path == "/tmp/a.m4a")
            #expect(prompt == "hi")
            #expect(safe == false)
        } else { Issue.record("wrong request case") }
    }

    @Test func eventRoundTripsResultAndError() throws {
        let id = UUID()
        let result = EventEnvelope(id: id, channel: .plugin,
            event: .transcriptionResult(TranscriptionResult(text: "x")))
        let rDecoded = try JSONDecoder().decode(
            EventEnvelope.self, from: try JSONEncoder().encode(result))
        if case let .transcriptionResult(tr) = rDecoded.event {
            #expect(tr.text == "x")
        } else { Issue.record("wrong event case") }

        let err = EventEnvelope(id: id, channel: .plugin,
            event: .error(WireError(kind: .insufficientMemory,
                                    message: "need 4 GB", model: "Large", requiredGB: "4.0")))
        let eDecoded = try JSONDecoder().decode(
            EventEnvelope.self, from: try JSONEncoder().encode(err))
        if case let .error(w) = eDecoded.event {
            #expect(w.kind == .insufficientMemory)
            #expect(w.requiredGB == "4.0")
        } else { Issue.record("wrong event case") }
    }

    @Test func ttsEngineRawValuesRoundTrip() {
        for engine in TTSEngine.allCases {
            #expect(TTSEngine(rawValue: engine.rawValue) == engine)
        }
        #expect(TTSEngine(rawValue: "qwen3") == .qwen3)
        #expect(TTSEngine(rawValue: "kokoro") == .kokoro)
        #expect(TTSEngine(rawValue: "bogus") == nil)
    }

    @Test func kokoroVoiceRawValuesAreFluidAudioIds() {
        // Raw values must match FluidAudio Kokoro voice ids verbatim (the helper
        // passes them straight to KokoroAneManager).
        #expect(KokoroVoice.afHeart.rawValue == "af_heart")
        for voice in KokoroVoice.allCases {
            #expect(KokoroVoice(rawValue: voice.rawValue) == voice)
            #expect(!voice.displayName.isEmpty)
            #expect(voice.language == "English")
        }
    }

    @Test func synthesizeSpeechCarriesEngine() throws {
        let req = RequestEnvelope(
            id: UUID(),
            request: .synthesizeSpeech(text: "hi", outputPath: "/tmp/a.wav",
                                       voice: "af_heart", language: nil,
                                       instruction: nil, model: nil, engine: "kokoro")
        )
        let decoded = try JSONDecoder().decode(
            RequestEnvelope.self, from: try JSONEncoder().encode(req))
        if case let .synthesizeSpeech(_, _, voice, _, _, _, engine) = decoded.request {
            #expect(voice == "af_heart")
            #expect(engine == "kokoro")
        } else { Issue.record("wrong request case") }
    }
}
