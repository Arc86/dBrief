import Foundation
@testable import dBrief
import Testing

struct SpeakerReassignmentTests {
    // Helper: build a transcript with N segments, given (speakerId) per segment.
    private func transcript(
        _ speakers: [String?],
        labels: [SpeakerLabel] = [],
        me: String? = nil
    ) -> RichTranscript {
        let segs = speakers.enumerated().map { i, sp in
            RichSegment(start: Double(i), end: Double(i) + 1,
                        text: "seg\(i)", originalText: "seg\(i)", speakerId: sp)
        }
        return RichTranscript(segments: segs, speakerLabels: labels, meSpeakerId: me)
    }

    @Test("theseSegments rewrites only the given ids")
    func theseSegmentsOnly() {
        let t = transcript(["S1", "S1", "S2"],
                           labels: [SpeakerLabel(id: "S1", displayName: "S1"),
                                    SpeakerLabel(id: "S2", displayName: "S2")])
        let firstId = t.segments[0].id
        let out = SpeakerReassignment.apply(.existing(speakerId: "S2"), to: t,
                                            segmentIds: [firstId], scope: .theseSegments,
                                            newId: "NEW")
        #expect(out.segments[0].speakerId == "S2")
        #expect(out.segments[1].speakerId == "S1")
        #expect(out.segments[2].speakerId == "S2")
    }

    @Test("allOfSpeaker rewrites every segment of the origin speaker")
    func allOfSpeaker() {
        let t = transcript(["S1", "S1", "S2"],
                           labels: [SpeakerLabel(id: "S1", displayName: "S1"),
                                    SpeakerLabel(id: "S2", displayName: "S2")])
        let firstId = t.segments[0].id
        let out = SpeakerReassignment.apply(.existing(speakerId: "S2"), to: t,
                                            segmentIds: [firstId], scope: .allOfSpeaker,
                                            newId: "NEW")
        #expect(out.segments.map(\.speakerId) == ["S2", "S2", "S2"])
    }

    @Test("no-op when target equals origin")
    func noOp() {
        let t = transcript(["S1", "S2"])
        let id0 = t.segments[0].id
        let out = SpeakerReassignment.apply(.existing(speakerId: "S1"), to: t,
                                            segmentIds: [id0], scope: .allOfSpeaker,
                                            newId: "NEW")
        #expect(out.segments.map(\.speakerId) == ["S1", "S2"])
    }

    @Test("full merge removes the orphaned label but keeps the target")
    func orphanCleanup() {
        let t = transcript(["S1", "S2"],
                           labels: [SpeakerLabel(id: "S1", displayName: "Alice"),
                                    SpeakerLabel(id: "S2", displayName: "Bob")])
        let id0 = t.segments[0].id
        let out = SpeakerReassignment.apply(.existing(speakerId: "S2"), to: t,
                                            segmentIds: [id0], scope: .allOfSpeaker,
                                            newId: "NEW")
        #expect(out.speakerLabels.contains { $0.id == "S2" })
        #expect(!out.speakerLabels.contains { $0.id == "S1" })
    }

    @Test("meSpeakerId transfers when its speaker is fully merged away")
    func meTransfer() {
        let t = transcript(["S1", "S2"],
                           labels: [SpeakerLabel(id: "S1", displayName: "Me"),
                                    SpeakerLabel(id: "S2", displayName: "Bob")],
                           me: "S1")
        let id0 = t.segments[0].id
        let out = SpeakerReassignment.apply(.existing(speakerId: "S2"), to: t,
                                            segmentIds: [id0], scope: .allOfSpeaker,
                                            newId: "NEW")
        #expect(out.meSpeakerId == "S2")
    }

    @Test("meSpeakerId untouched when its speaker still has segments")
    func meUntouched() {
        let t = transcript(["S1", "S1", "S2"], me: "S1")
        let id0 = t.segments[0].id
        let out = SpeakerReassignment.apply(.existing(speakerId: "S2"), to: t,
                                            segmentIds: [id0], scope: .theseSegments,
                                            newId: "NEW")
        #expect(out.meSpeakerId == "S1")
    }

    @Test("segmentCount counts segments for a speaker")
    func segmentCount() {
        let t = transcript(["S1", "S1", "S2", nil])
        #expect(SpeakerReassignment.segmentCount(in: t, speakerId: "S1") == 2)
        #expect(SpeakerReassignment.segmentCount(in: t, speakerId: "S2") == 1)
        #expect(SpeakerReassignment.segmentCount(in: t, speakerId: nil) == 0)
    }

    @Test("new name matching an existing label (case-insensitive) reuses its id")
    func newNameReusesExistingLabel() {
        let t = transcript(["S1", "S2"],
                           labels: [SpeakerLabel(id: "S1", displayName: "Alice"),
                                    SpeakerLabel(id: "S2", displayName: "Bob")])
        let id1 = t.segments[1].id   // currently S2
        let out = SpeakerReassignment.apply(.new(name: "ALICE"), to: t,
                                            segmentIds: [id1], scope: .theseSegments,
                                            newId: "NEW")
        #expect(out.segments[1].speakerId == "S1")          // reused, not minted
        #expect(!out.speakerLabels.contains { $0.id == "NEW" })
        #expect(out.speakerLabels.count == 1)               // S2 orphaned; no duplicate Alice label
    }

    @Test("candidates put the current speaker first and flag it")
    func candidatesCurrentFirst() {
        let t = transcript(["S2", "S1"],
                           labels: [SpeakerLabel(id: "S1", displayName: "Alice"),
                                    SpeakerLabel(id: "S2", displayName: "Bob")])
        let cands = SpeakerReassignment.candidates(in: t, currentSpeakerId: "S2",
                                                   participants: [], calendarAttendees: [])
        #expect(cands.first?.existingSpeakerId == "S2")
        #expect(cands.first?.isCurrent == true)
        #expect(cands.count == 2)
        #expect(cands.contains { $0.existingSpeakerId == "S1" && !$0.isCurrent })
    }

    @Test("unlabeled speakers display their raw id")
    func candidatesUnlabeled() {
        let t = transcript(["S1", "S2"])  // no labels
        let cands = SpeakerReassignment.candidates(in: t, currentSpeakerId: "S1",
                                                   participants: [], calendarAttendees: [])
        #expect(cands.contains { $0.existingSpeakerId == "S2" && $0.displayName == "S2" })
    }

    @Test("participant names not yet speakers appear as name-only candidates")
    func candidatesNameOnly() {
        let t = transcript(["S1"], labels: [SpeakerLabel(id: "S1", displayName: "Alice")])
        let cands = SpeakerReassignment.candidates(in: t, currentSpeakerId: "S1",
                                                   participants: ["Carol", "alice"],
                                                   calendarAttendees: ["Carol", "Dave"])
        // "alice" deduped against existing "Alice"; "Carol" deduped across the two lists.
        let nameOnly = cands.filter { $0.existingSpeakerId == nil }
        #expect(nameOnly.map(\.displayName).sorted() == ["Carol", "Dave"])
        #expect(nameOnly.allSatisfy { $0.id.hasPrefix("name:") })
    }
}
