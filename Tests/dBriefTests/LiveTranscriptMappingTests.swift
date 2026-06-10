import Foundation
import Testing
@testable import dBriefWire

@Suite("Live transcript mapping")
struct LiveTranscriptMappingTests {
    @Test("Maps chunks to speaker-tagged live segments")
    func mapsLiveSegmentsWithSpeaker() {
        let chunks = [
            AppleSpeechChunk(text: " Hello there", start: 0.0, end: 1.2, runs: []),
            AppleSpeechChunk(text: "How are you", start: 1.3, end: 2.4, runs: []),
        ]

        let segments = AppleSpeechResultMapper.liveSegments(from: chunks, speaker: "You")

        #expect(segments.count == 2)
        #expect(segments[0].text == "Hello there")
        #expect(segments[0].speaker == "You")
        #expect(segments[0].start == 0.0)
        #expect(segments[0].end == 1.2)
        #expect(segments[1].text == "How are you")
        #expect(segments[1].speaker == "You")
    }

    @Test("Drops whitespace-only chunks")
    func dropsEmptyLiveChunks() {
        let chunks = [
            AppleSpeechChunk(text: "   ", start: 0.0, end: 0.2, runs: []),
            AppleSpeechChunk(text: "Real text", start: 0.3, end: 1.0, runs: []),
            AppleSpeechChunk(text: "", start: 1.1, end: 1.2, runs: []),
        ]

        let segments = AppleSpeechResultMapper.liveSegments(from: chunks, speaker: "Participant")

        #expect(segments.count == 1)
        #expect(segments[0].text == "Real text")
        #expect(segments[0].speaker == "Participant")
    }

    @Test("Nil speaker is preserved")
    func nilSpeaker() {
        let chunks = [AppleSpeechChunk(text: "No speaker", start: 0, end: 1, runs: [])]
        let segments = AppleSpeechResultMapper.liveSegments(from: chunks, speaker: nil)
        #expect(segments.count == 1)
        #expect(segments[0].speaker == nil)
    }
}

@Suite("Live segment merge")
struct LiveSegmentMergeTests {
    private func seg(_ start: Double, _ speaker: String) -> LiveTranscriptSegment {
        LiveTranscriptSegment(start: start, end: start + 0.5, text: speaker, speaker: speaker)
    }

    @Test("Inserts keeping ascending start order across two channels")
    func mergeByStart() {
        var timeline: [LiveTranscriptSegment] = []
        // Arrive out of order, as two concurrent recognizers would.
        timeline = LiveSegmentMerge.insert(seg(0.0, "You"), into: timeline)
        timeline = LiveSegmentMerge.insert(seg(2.0, "Participant"), into: timeline)
        timeline = LiveSegmentMerge.insert(seg(1.0, "You"), into: timeline)
        timeline = LiveSegmentMerge.insert(seg(0.5, "Participant"), into: timeline)

        #expect(timeline.map(\.start) == [0.0, 0.5, 1.0, 2.0])
        #expect(timeline.map(\.speaker) == ["You", "Participant", "You", "Participant"])
    }

    @Test("Equal starts keep insertion order (stable)")
    func stableEqualStarts() {
        var timeline: [LiveTranscriptSegment] = []
        timeline = LiveSegmentMerge.insert(seg(1.0, "You"), into: timeline)
        timeline = LiveSegmentMerge.insert(seg(1.0, "Participant"), into: timeline)
        #expect(timeline.map(\.speaker) == ["You", "Participant"])
    }

    @Test("Batch insert orders all new segments")
    func batchInsert() {
        let existing = [seg(1.0, "You")]
        let result = LiveSegmentMerge.insert([seg(0.0, "Participant"), seg(2.0, "Participant")], into: existing)
        #expect(result.map(\.start) == [0.0, 1.0, 2.0])
    }
}
