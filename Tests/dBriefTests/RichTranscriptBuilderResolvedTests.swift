import Foundation
import Testing
@testable import dBrief
import dBriefWire

@Suite("RichTranscriptBuilder resolved identities")
struct RichTranscriptBuilderResolvedTests {
    private func result(_ speakers: [String]) -> TranscriptionResult {
        let segs = speakers.enumerated().map { i, s in
            TranscriptionResult.Segment(start: Double(i), end: Double(i) + 1, text: "x", speaker: s)
        }
        return TranscriptionResult(text: "x", segments: segs)
    }

    @Test("Resolved match wins over ordinal participant mapping")
    func resolvedWins() {
        let r = result(["Speaker 1", "Speaker 2"])
        let rich = RichTranscriptBuilder().build(
            from: r,
            participants: ["Alice", "Bob"],
            resolved: ["Speaker 2": .init(name: "Erwin", personId: "erwin")])
        let s2 = rich.speakerLabels.first { $0.id == "Speaker 2" }
        #expect(s2?.displayName == "Erwin")
        #expect(s2?.personId == "erwin")
        // Speaker 1 falls back to the first *unused* participant.
        let s1 = rich.speakerLabels.first { $0.id == "Speaker 1" }
        #expect(s1?.displayName == "Alice")
        #expect(s1?.personId == nil)
    }

    @Test("A participant consumed by a resolved match isn't reused by ordinal")
    func noDuplicateNames() {
        let r = result(["Speaker 1", "Speaker 2"])
        let rich = RichTranscriptBuilder().build(
            from: r,
            participants: ["Erwin", "Bob"],
            resolved: ["Speaker 2": .init(name: "Erwin", personId: "erwin")])
        let names = Set(rich.speakerLabels.map(\.displayName))
        #expect(names == ["Erwin", "Bob"])           // not ["Erwin", "Erwin"]
        #expect(rich.speakerLabels.first { $0.id == "Speaker 1" }?.displayName == "Bob")
    }

    @Test("suppressOrdinalGuess keeps unmatched speakers as raw ids (no swap guess)")
    func suppressOrdinalGuess() {
        let r = result(["Speaker 1", "Speaker 2"])
        let rich = RichTranscriptBuilder().build(
            from: r,
            participants: ["Alice", "Bob"],
            resolved: ["Speaker 1": .init(name: "Erwin", personId: "erwin")],
            suppressOrdinalGuess: true)
        // Resolved match still applies…
        #expect(rich.speakerLabels.first { $0.id == "Speaker 1" }?.displayName == "Erwin")
        // …but the unmatched speaker is NOT ordinal-guessed — it stays raw.
        let s2 = rich.speakerLabels.first { $0.id == "Speaker 2" }
        #expect(s2?.displayName == "Speaker 2")
        #expect(s2?.personId == nil)
    }

    @Test("Empty resolved map preserves existing ordinal behavior")
    func emptyResolvedUnchanged() {
        let r = result(["Speaker 1", "Speaker 2"])
        let rich = RichTranscriptBuilder().build(from: r, participants: ["Alice", "Bob"], resolved: [:])
        // sorted unique ids → Speaker 1, Speaker 2 ; participants by ordinal
        #expect(rich.speakerLabels.first { $0.id == "Speaker 1" }?.displayName == "Alice")
        #expect(rich.speakerLabels.first { $0.id == "Speaker 2" }?.displayName == "Bob")
    }
}
