import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite @MainActor struct LiveTurnBuilderTests {
    private func seg(_ s: Double, _ e: Double, _ text: String, _ speaker: String?) -> LiveTranscriptSegment {
        LiveTranscriptSegment(start: s, end: e, text: text, speaker: speaker)
    }

    @Test func freshlyMappedSegmentsKeepTurnIDs() {
        // Two separately constructed arrays with equal values, like
        // ProcessingJob.transcriptPreviewSegments returns on each read.
        let a = [seg(0, 1, "Hi", "You"), seg(1, 2, "Hello", "Participant")]
        let b = [seg(0, 1, "Hi", "You"), seg(1, 2, "Hello", "Participant")]
        #expect(LiveTurnBuilder.turns(from: a).map(\.id) == LiveTurnBuilder.turns(from: b).map(\.id))
    }

    @Test func appendingASegmentKeepsEarlierTurnIDs() {
        let base = [seg(0, 1, "Hi", "You"), seg(1, 2, "Hello", "Participant")]
        let before = LiveTurnBuilder.turns(from: base).map(\.id)
        let after = LiveTurnBuilder.turns(from: base + [seg(2, 3, "Next", "You")]).map(\.id)
        #expect(Array(after.prefix(2)) == before)
        #expect(after.count == 3)
    }

    @Test func sameSpeakerContinuationKeepsTheTurnID() {
        let base = [seg(0, 1, "Hi", "You")]
        let before = LiveTurnBuilder.turns(from: base)
        let after = LiveTurnBuilder.turns(from: base + [seg(1, 2, "there", "You")])
        #expect(after.count == 1)
        #expect(after[0].id == before[0].id)
        #expect(after[0].text == "Hi there")
    }

    @Test func identicalTimingStillYieldsUniqueIDs() {
        let segments = [seg(0, 1, "A", "You"), seg(1, 2, "B", "Participant"), seg(0, 1, "A", "You")]
        let ids = LiveTurnBuilder.turns(from: segments).map(\.id)
        #expect(ids.count == 3)
        #expect(Set(ids).count == 3)
    }

    @Test func speakerChangesTheID() {
        #expect(LiveTurnBuilder.stableID(start: 0, end: 1, speaker: "You", salt: 0)
             != LiveTurnBuilder.stableID(start: 0, end: 1, speaker: "Participant", salt: 0))
    }
}
