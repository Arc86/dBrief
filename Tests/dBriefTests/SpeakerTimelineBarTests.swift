import SwiftUI
import Testing
@testable import dBrief

@Suite struct SpeakerTimelineBarTests {
    @Test func consecutiveSamplesMergeIntoRuns() {
        let runs = SpeakerTimelineBarLayout.runs(sampledIDs: ["A", "A", nil, "B", "B", "B"])
        #expect(runs == [
            SpeakerTimelineRun(start: 0, end: 2.0 / 6, speakerID: "A"),
            SpeakerTimelineRun(start: 2.0 / 6, end: 3.0 / 6, speakerID: nil),
            SpeakerTimelineRun(start: 3.0 / 6, end: 1, speakerID: "B"),
        ])
    }

    @Test func emptyInputHasNoRuns() {
        #expect(SpeakerTimelineBarLayout.runs(sampledIDs: []).isEmpty)
    }

    @Test func runsCoverTheWholeBarWithoutGaps() {
        let ids: [String?] = (0..<600).map { $0 % 50 < 20 ? "A" : ($0 % 50 < 30 ? nil : "B") }
        let runs = SpeakerTimelineBarLayout.runs(sampledIDs: ids)
        #expect(runs.first?.start == 0)
        #expect(runs.last?.end == 1)
        for (a, b) in zip(runs, runs.dropFirst()) {
            #expect(a.end == b.start)
            #expect(a.speakerID != b.speakerID)
        }
    }

    @Test func theStaticStripIgnoresPlaybackPosition() {
        // The strip has no playback input at all, so ticks cannot redraw it.
        let runs = SpeakerTimelineBarLayout.runs(sampledIDs: ["A", nil])
        let strip = SpeakerTimelineStrip(runs: runs, colors: ["A": .blue], neutral: .gray, played: false)
        #expect(strip == SpeakerTimelineStrip(runs: runs, colors: ["A": .blue], neutral: .gray, played: false))
        #expect(strip != SpeakerTimelineStrip(runs: runs, colors: ["A": .blue], neutral: .gray, played: true))
    }
}
