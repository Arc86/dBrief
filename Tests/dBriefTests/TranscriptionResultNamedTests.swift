import Foundation
import Testing
@testable import dBriefWire

@Suite("TranscriptionResult name-aware textForLLM")
struct TranscriptionResultNamedTests {
    private func sample() -> TranscriptionResult {
        TranscriptionResult(
            text: "Hi there. Hello. Bye now.",
            segments: [
                .init(start: 0, end: 1, text: "Hi there.", speaker: "Speaker 1"),
                .init(start: 1, end: 2, text: "Hello.", speaker: "Speaker 2"),
                .init(start: 2, end: 3, text: "Bye now.", speaker: "Speaker 1"),
            ]
        )
    }

    @Test("Substitutes display names for mapped speaker IDs")
    func substitutesNames() {
        let out = sample().textForLLM(speakerNames: ["Speaker 1": "Alice", "Speaker 2": "Bob"])
        #expect(out == "Alice: Hi there.\nBob: Hello.\nAlice: Bye now.")
    }

    @Test("Unmapped or blank names fall back to the raw speaker ID")
    func fallsBackToRawID() {
        let out = sample().textForLLM(speakerNames: ["Speaker 1": "  "])
        #expect(out == "Speaker 1: Hi there.\nSpeaker 2: Hello.\nSpeaker 1: Bye now.")
    }

    @Test("Empty map matches the legacy textForLLM exactly")
    func emptyMapMatchesLegacy() {
        let r = sample()
        #expect(r.textForLLM(speakerNames: [:]) == r.textForLLM)
        #expect(r.textForLLM == "Speaker 1: Hi there.\nSpeaker 2: Hello.\nSpeaker 1: Bye now.")
    }

    @Test("No speaker info yields space-joined segment text")
    func noSpeakerInfo() {
        let r = TranscriptionResult(
            text: "a b",
            segments: [.init(start: 0, end: 1, text: "a"), .init(start: 1, end: 2, text: "b")]
        )
        #expect(r.textForLLM(speakerNames: ["Speaker 1": "Alice"]) == "a b")
    }
}
