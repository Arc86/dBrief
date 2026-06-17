import Foundation
import Testing
@testable import dBriefWire

@Suite("SpeakerClipRanges")
struct SpeakerClipRangesTests {
    private func seg(_ s: Double, _ e: Double, _ spk: String?) -> TranscriptionResult.Segment {
        .init(start: s, end: e, text: "x", speaker: spk)
    }

    @Test("Groups by speaker and converts seconds to clamped sample ranges")
    func groupsAndClamps() {
        let segs = [seg(0, 2, "A"), seg(2, 4, "B"), seg(4, 6, "A")]
        let r = SpeakerClipRanges.build(segments: segs, totalSamples: 16000 * 5, sampleRate: 16000, minSeconds: 1.5)
        // A: 0..32000 and 64000..80000 (clamped to 80000), B: 32000..64000
        #expect(r["A"] == [0..<32000, 64000..<80000])
        #expect(r["B"] == [32000..<64000])
    }

    @Test("Drops speakers below the minimum duration")
    func dropsShortSpeakers() {
        let segs = [seg(0, 3, "A"), seg(3, 3.5, "B")] // B = 0.5s < 1.5s
        let r = SpeakerClipRanges.build(segments: segs, totalSamples: 16000 * 4, sampleRate: 16000, minSeconds: 1.5)
        #expect(r["A"] != nil)
        #expect(r["B"] == nil)
    }

    @Test("Ignores nil-speaker segments and empty/zero-length ranges")
    func ignoresNilAndEmpty() {
        let segs = [seg(0, 2, nil), seg(2, 2, "A"), seg(2, 4, "A")]
        let r = SpeakerClipRanges.build(segments: segs, totalSamples: 16000 * 4, sampleRate: 16000, minSeconds: 1.5)
        #expect(r.keys.sorted() == ["A"])
        #expect(r["A"] == [32000..<64000]) // the zero-length 2..2 dropped
    }
}
