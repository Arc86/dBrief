import Foundation
import Testing
@testable import dBrief
import dBriefWire

@Suite("SegmentSpeakerReconciler.reconcile")
struct SegmentSpeakerReconcilerTests {

    // Build a part from (speaker, embedding) pairs; one 1-second segment per speaker.
    private func part(_ speakers: [(id: String, vec: [Float]?)]) -> SegmentSpeakerReconciler.Part {
        var segs: [TranscriptionResult.Segment] = []
        var emb: [String: [Float]] = [:]
        for (i, s) in speakers.enumerated() {
            segs.append(.init(start: Double(i), end: Double(i) + 1, text: "hi", words: nil, speaker: s.id))
            if let v = s.vec { emb[s.id] = v }
        }
        return .init(segments: segs, speakerEmbeddings: emb.isEmpty ? nil : emb)
    }

    @Test("Same speaker across two parts merges to one global")
    func sameSpeakerMerges() {
        let p1 = part([("Speaker 1", [1, 0])])
        let p2 = part([("Speaker 1", [0.98, 0.20])]) // cosine ~0.98 ≥ 0.5
        let r = SegmentSpeakerReconciler.reconcile([p1, p2])
        #expect(r.speakerCount == 1)
        #expect(r.remaps[0]["Speaker 1"] == "Speaker 1")
        #expect(r.remaps[1]["Speaker 1"] == "Speaker 1")
        // global embedding is the mean of the two contributing vectors
        let g = r.speakerEmbeddings["Speaker 1"]
        #expect(g?.count == 2)
        #expect(abs((g?[0] ?? 0) - 0.99) < 1e-5)
        #expect(abs((g?[1] ?? 0) - 0.10) < 1e-5)
    }

    @Test("Different speakers across two parts stay distinct")
    func differentSpeakersStayDistinct() {
        let p1 = part([("Speaker 1", [1, 0])])
        let p2 = part([("Speaker 1", [0, 1])]) // cosine 0 < 0.5 → new global
        let r = SegmentSpeakerReconciler.reconcile([p1, p2])
        #expect(r.speakerCount == 2)
        #expect(r.remaps[0]["Speaker 1"] == "Speaker 1")
        #expect(r.remaps[1]["Speaker 1"] == "Speaker 2")
    }

    @Test("Two real people across three parts, one absent from the middle part")
    func threePartsTwoPeople() {
        let alice: [Float] = [1, 0]
        let bob: [Float] = [0, 1]
        let p1 = part([("Speaker 1", alice), ("Speaker 2", bob)])
        let p2 = part([("Speaker 1", bob)])                 // only Bob speaks
        let p3 = part([("Speaker 1", alice)])               // Alice returns
        let r = SegmentSpeakerReconciler.reconcile([p1, p2, p3])
        #expect(r.speakerCount == 2)
        let aliceGlobal = r.remaps[0]["Speaker 1"]          // Alice's global id
        let bobGlobal = r.remaps[0]["Speaker 2"]            // Bob's global id
        #expect(r.remaps[1]["Speaker 1"] == bobGlobal)      // part 2 → Bob
        #expect(r.remaps[2]["Speaker 1"] == aliceGlobal)    // part 3 → Alice
    }

    @Test("A part missing embeddings yields distinct globals, never a mislabel")
    func missingEmbeddingsNamespaces() {
        let p1 = part([("Speaker 1", [1, 0] as [Float]?)])
        let p2 = part([("Speaker 1", nil as [Float]?)])                 // no embedding → cannot match
        let r = SegmentSpeakerReconciler.reconcile([p1, p2])
        #expect(r.speakerCount == 2)
        #expect(r.remaps[1]["Speaker 1"] == "Speaker 2")
    }

    @Test("No diarization (nil speakers) → empty remaps, no embeddings, zero count")
    func noDiarizationPassThrough() {
        let segs: [TranscriptionResult.Segment] = [.init(start: 0, end: 1, text: "hi", words: nil, speaker: nil)]
        let p = SegmentSpeakerReconciler.Part(segments: segs, speakerEmbeddings: nil as [String: [Float]]?)
        let r = SegmentSpeakerReconciler.reconcile([p])
        #expect(r.speakerCount == 0)
        #expect(r.speakerEmbeddings.isEmpty)
        #expect(r.remaps[0].isEmpty)
    }

    @Test("Deterministic global-id assignment by part then local-id order")
    func deterministic() {
        // Part 1 introduces S2 then S1 (unsorted); ids assign in local-id sort order.
        let p1 = part([("Speaker 2", [1, 0]), ("Speaker 1", [0, 1])])
        let r = SegmentSpeakerReconciler.reconcile([p1])
        #expect(r.remaps[0]["Speaker 1"] == "Speaker 1") // sorted first → global 1
        #expect(r.remaps[0]["Speaker 2"] == "Speaker 2")
    }
}
