import Foundation
import Testing
@testable import dBrief

@Suite("SpeakerReassignment known people")
struct SpeakerReassignmentKnownPeopleTests {
    private func transcript() -> RichTranscript {
        RichTranscript(segments: [
            RichSegment(start: 0, end: 1, text: "a", originalText: "a", speakerId: "Speaker 1"),
            RichSegment(start: 1, end: 2, text: "b", originalText: "b", speakerId: "Speaker 2"),
        ], speakerLabels: [
            SpeakerLabel(id: "Speaker 1", displayName: "Speaker 1"),
            SpeakerLabel(id: "Speaker 2", displayName: "Speaker 2"),
        ])
    }

    @Test("Known people appear as name-only candidates, de-duped")
    func knownPeopleAdded() {
        let cands = SpeakerReassignment.candidates(
            in: transcript(), currentSpeakerId: "Speaker 1",
            participants: ["Bob"], calendarAttendees: [],
            knownPeople: ["Erwin", "Bob"])   // Bob already a participant → not duplicated
        let names = cands.map(\.displayName)
        #expect(names.contains("Erwin"))
        #expect(names.filter { $0 == "Bob" }.count == 1)
    }

    @Test("Rename to a known person records personId on the label")
    func renameLinksPersonId() {
        let out = SpeakerReassignment.rename(transcript(), speakerId: "Speaker 1", to: "Erwin", personId: "erwin")
        let label = out.speakerLabels.first { $0.id == "Speaker 1" }
        #expect(label?.displayName == "Erwin")
        #expect(label?.personId == "erwin")
    }

    @Test("Rename without personId leaves it nil (free-typed name)")
    func renameNoPersonId() {
        let out = SpeakerReassignment.rename(transcript(), speakerId: "Speaker 1", to: "Mystery")
        #expect(out.speakerLabels.first { $0.id == "Speaker 1" }?.personId == nil)
    }
}
