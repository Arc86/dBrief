import Foundation
import Testing
@testable import dBrief

@Suite @MainActor struct SpeakerMenuCacheTests {
    private func transcript() -> RichTranscript {
        RichTranscript(
            segments: [
                RichSegment(start: 0, end: 1, text: "a", originalText: "a", speakerId: "S1"),
                RichSegment(start: 1, end: 2, text: "b", originalText: "b", speakerId: "S2"),
                RichSegment(start: 2, end: 3, text: "c", originalText: "c", speakerId: "S1"),
            ],
            speakerLabels: [SpeakerLabel(id: "S1", displayName: "Alice"), SpeakerLabel(id: "S2", displayName: "Bob")])
    }

    private func inputs(revision: Int = 1, known: [String] = []) -> SpeakerMenuCache.Inputs {
        .init(revision: revision, transcript: transcript(), participants: ["Alice"],
              attendees: ["Carol"], knownPeople: known)
    }

    @Test func dataIsComputedOncePerSpeakerNotOncePerRow() {
        let cache = SpeakerMenuCache()
        let input = inputs()
        for _ in 0..<200 { _ = cache.data(for: "S1", inputs: input) }
        #expect(cache.computeCount == 1)
        _ = cache.data(for: "S2", inputs: input)
        #expect(cache.computeCount == 2)
    }

    @Test func aNewTranscriptRevisionRecomputes() {
        let cache = SpeakerMenuCache()
        _ = cache.data(for: "S1", inputs: inputs(revision: 1))
        _ = cache.data(for: "S1", inputs: inputs(revision: 2))
        #expect(cache.computeCount == 2)
    }

    @Test func changedKnownPeopleRecomputes() {
        let cache = SpeakerMenuCache()
        _ = cache.data(for: "S1", inputs: inputs(known: []))
        let updated = cache.data(for: "S1", inputs: inputs(known: ["Dave"]))
        #expect(cache.computeCount == 2)
        #expect(updated.libraryNames.contains("Dave"))
    }

    @Test func segmentCountAndMoveTargetsMatchTheTranscript() {
        let cache = SpeakerMenuCache()
        let data = cache.data(for: "S1", inputs: inputs())
        #expect(data.segmentCount == 2)
        #expect(data.others.map(\.id) == ["S2"])
        #expect(data.meetingNames.contains("Carol"))
    }
}
