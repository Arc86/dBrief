import Testing
@testable import dBrief

@Suite("Speaker timeline and identity palette")
struct SpeakerTimelineTests {
    private func segment(
        start: Double,
        end: Double,
        speakerID: String? = nil
    ) -> RichSegment {
        RichSegment(
            start: start,
            end: end,
            text: "speech",
            originalText: "speech",
            speakerId: speakerID
        )
    }

    @Test func normalizesOutOfOrderSegmentsClipsAndRetainsUnknownSpeakerIntervals() {
        let ranges = SpeakerTimeline.normalize([
            segment(start: 5, end: 12, speakerID: "C"),
            segment(start: -2, end: 1, speakerID: "A"),
            segment(start: 2, end: 4),
            segment(start: 3, end: 5, speakerID: "B"),
        ], duration: 10)

        #expect(ranges == [
            SpeakerTimeRange(start: 0, end: 1, speakerID: "A"),
            SpeakerTimeRange(start: 2, end: 4, speakerID: ""),
            SpeakerTimeRange(start: 3, end: 5, speakerID: "B"),
            SpeakerTimeRange(start: 5, end: 10, speakerID: "C"),
        ])
    }

    @Test func ignoresInvalidIntervalsAndInvalidDurations() {
        let valid = segment(start: 1, end: 2, speakerID: "A")
        let invalid = [
            segment(start: .nan, end: 1, speakerID: "nan-start"),
            segment(start: 1, end: .infinity, speakerID: "infinite-end"),
            segment(start: 3, end: 2, speakerID: "reversed"),
            segment(start: 2, end: 2, speakerID: "empty"),
            segment(start: 3, end: 4, speakerID: "outside"),
        ]

        #expect(SpeakerTimeline.normalize([valid] + invalid, duration: 2) == [
            SpeakerTimeRange(start: 1, end: 2, speakerID: "A"),
        ])
        #expect(SpeakerTimeline.normalize([valid], duration: 0).isEmpty)
        #expect(SpeakerTimeline.normalize([valid], duration: -1).isEmpty)
        #expect(SpeakerTimeline.normalize([valid], duration: .nan).isEmpty)
        #expect(SpeakerTimeline.normalize([valid], duration: .infinity).isEmpty)
    }

    @Test func lookupUsesHalfOpenRangesAndMakesGapsAndDistinctOverlapsNeutral() {
        let ranges = [
            SpeakerTimeRange(start: 0, end: 2, speakerID: "A"),
            SpeakerTimeRange(start: 3, end: 5, speakerID: "B"),
            SpeakerTimeRange(start: 4, end: 6, speakerID: "C"),
        ]

        #expect(SpeakerTimeline.speakerID(at: 0, in: ranges) == "A")
        #expect(SpeakerTimeline.speakerID(at: 1.999, in: ranges) == "A")
        #expect(SpeakerTimeline.speakerID(at: 2, in: ranges) == nil)
        #expect(SpeakerTimeline.speakerID(at: 2.5, in: ranges) == nil)
        #expect(SpeakerTimeline.speakerID(at: 3, in: ranges) == "B")
        #expect(SpeakerTimeline.speakerID(at: 4.5, in: ranges) == nil)
        #expect(SpeakerTimeline.speakerID(at: 6, in: ranges) == nil)
        #expect(SpeakerTimeline.speakerID(at: .infinity, in: ranges) == nil)
        #expect(SpeakerTimeline.speakerID(at: .nan, in: ranges) == nil)
    }

    @Test func sameSpeakerOverlapKeepsIdentityButUnknownOverlapStaysNeutral() {
        let sameSpeaker = [
            SpeakerTimeRange(start: 0, end: 3, speakerID: "A"),
            SpeakerTimeRange(start: 1, end: 4, speakerID: "A"),
        ]
        #expect(SpeakerTimeline.speakerID(at: 2, in: sameSpeaker) == "A")

        let unknownAlone = [SpeakerTimeRange(start: 0, end: 4, speakerID: "")]
        #expect(SpeakerTimeline.speakerID(at: 2, in: unknownAlone) == nil)

        let unknownOverKnown = [
            SpeakerTimeRange(start: 0, end: 4, speakerID: "A"),
            SpeakerTimeRange(start: 1, end: 3, speakerID: ""),
        ]
        #expect(SpeakerTimeline.speakerID(at: 0.5, in: unknownOverKnown) == "A")
        #expect(SpeakerTimeline.speakerID(at: 2, in: unknownOverKnown) == nil)

        let whitespaceOverKnown = [
            SpeakerTimeRange(start: 0, end: 4, speakerID: "A"),
            SpeakerTimeRange(start: 1, end: 3, speakerID: " \t "),
        ]
        #expect(SpeakerTimeline.speakerID(at: 2, in: whitespaceOverKnown) == nil)
        #expect(SpeakerTimeline.sampledSpeakerIDs(in: whitespaceOverKnown, duration: 4, count: 2)
                == [nil, "A"])

        #expect(SpeakerTimeline.normalize([
            segment(start: 1, end: 3, speakerID: " \t "),
        ], duration: 4) == [SpeakerTimeRange(start: 1, end: 3, speakerID: "")])
    }

    @Test func sampledSpeakerIDsUseBarCentresAndReturnNeutralForGapsOrOverlaps() {
        let ranges = [
            SpeakerTimeRange(start: 3, end: 4, speakerID: "C"),
            SpeakerTimeRange(start: 0, end: 1, speakerID: "A"),
            SpeakerTimeRange(start: 1, end: 2, speakerID: "B"),
            SpeakerTimeRange(start: 2.25, end: 2.75, speakerID: "D"),
            SpeakerTimeRange(start: 2.5, end: 3.25, speakerID: "E"),
        ]

        #expect(SpeakerTimeline.sampledSpeakerIDs(in: ranges, duration: 4, count: 4)
                == ["A", "B", nil, "C"])
        #expect(SpeakerTimeline.sampledSpeakerIDs(in: ranges, duration: 4, count: 0).isEmpty)
        #expect(SpeakerTimeline.sampledSpeakerIDs(in: ranges, duration: 4, count: -3).isEmpty)
        #expect(SpeakerTimeline.sampledSpeakerIDs(in: ranges, duration: 0, count: 4).isEmpty)
        #expect(SpeakerTimeline.sampledSpeakerIDs(in: ranges, duration: .nan, count: 4).isEmpty)
    }

    @Test func speakerIDsDoNotNeedLabelsAndUseStableUnicodeIdentitySlots() {
        // Both identifiers have Unicode-scalar sums congruent to one modulo eight.
        #expect(ViewerSpeakerPalette.color(for: "I", mode: .light)
                == ViewerSpeakerPalette.color(for: "💡", mode: .light))
    }

    @Test func renamingAndMarkingMeDoNotChangeSpeakerColoursInAnyTheme() {
        let segment = self.segment(start: 0, end: 1, speakerID: "H")
        let before = RichTranscript(
            segments: [segment],
            speakerLabels: [SpeakerLabel(id: "H", displayName: "Original name")]
        )
        let after = RichTranscript(
            segments: [segment],
            speakerLabels: [SpeakerLabel(id: "H", displayName: "Renamed person")],
            meSpeakerId: "H"
        )
        let beforeRanges = SpeakerTimeline.normalize(before.segments, duration: 1)
        let afterRanges = SpeakerTimeline.normalize(after.segments, duration: 1)
        #expect(beforeRanges == afterRanges)

        let modes = ViewerAppearanceMode.allCases
        for mode in modes {
            let beforeID = beforeRanges.first?.speakerID
            let afterID = afterRanges.first?.speakerID
            #expect(ViewerSpeakerPalette.color(for: beforeID, mode: mode)
                    == ViewerSpeakerPalette.color(for: afterID, mode: mode))
            let blue = ViewerSpeakerPalette.color(for: "H", mode: mode)
            #expect(blue != ViewerSpeakerPalette.color(for: "I", mode: mode))
            #expect(blue != ViewerSpeakerPalette.color(for: "J", mode: mode))
            #expect(ViewerSpeakerPalette.color(for: nil, mode: mode) != blue)
            #expect(ViewerSpeakerPalette.color(for: nil, mode: mode)
                    == ViewerSpeakerPalette.color(for: "", mode: mode))
        }
        #expect(ViewerSpeakerPalette.color(for: " \n ", mode: .light)
                == ViewerSpeakerPalette.color(for: nil, mode: .light))

        #expect(ViewerSpeakerPalette.color(for: "H", mode: .light).hex == "#3371CD")
        #expect(ViewerSpeakerPalette.color(for: "I", mode: .light).hex == "#9854BD")
        #expect(ViewerSpeakerPalette.color(for: "J", mode: .light).hex == "#16827C")
        #expect(ViewerSpeakerPalette.color(for: "H", mode: .dark)
                != ViewerSpeakerPalette.color(for: "H", mode: .light))
        #expect(ViewerSpeakerPalette.color(for: "H", mode: .darkPaper)
                != ViewerSpeakerPalette.color(for: "H", mode: .dark))
    }
}
