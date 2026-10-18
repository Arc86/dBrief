import Foundation
import Testing
@testable import dBrief

@MainActor
struct SpeakerReviewDraftTests {
    private func item(_ id: String, name: String? = nil, personID: String? = nil) -> SpeakerReviewItem {
        .init(id: id, proposedName: name ?? id, reason: name == nil ? .belowThreshold : .matched,
              confidence: name == nil ? 0 : 0.8, personId: personID, clusterEmbedding: [], snippet: nil)
    }

    @Test("A manual correction never retains the old voice-library identity")
    func manualCorrectionClearsIdentity() {
        let draft = SpeakerReviewDraft(items: [item("Speaker 1", name: "Jesper Mol", personID: "jesper")])
        draft.search = "  Alex de Jong \n"
        draft.useTypedName()
        #expect(draft.edits["Speaker 1"] == ConfirmedSpeaker(name: "Alex de Jong", personId: nil))
        #expect(draft.reviewedIDs == ["Speaker 1"])
    }

    @Test("Switching speakers preserves assignments and clears the previous search")
    func independentAssignments() {
        let draft = SpeakerReviewDraft(items: [item("Speaker 1"), item("Speaker 2")])
        draft.assign(.init(id: "alex", name: "Alex", personId: "alex", detail: nil))
        draft.search = "Unsaved"
        draft.selectSpeaker("Speaker 1")
        #expect(draft.search.isEmpty)
        draft.selectSpeaker("Speaker 2")
        draft.search = "Bob"
        draft.useTypedName()
        #expect(draft.edits["Speaker 1"]?.personId == "alex")
        #expect(draft.edits["Speaker 2"] == ConfirmedSpeaker(name: "Bob", personId: nil))
    }

    @Test("Keeping a label removes a suggested library identity; blank manual input leaves it intact")
    func keepUnnamed() {
        let draft = SpeakerReviewDraft(items: [item("Speaker 1", name: "Jesper Mol", personID: "jesper")])
        draft.search = " \n "
        draft.useTypedName()
        #expect(draft.edits["Speaker 1"]?.personId == "jesper")
        draft.keepUnnamed()
        #expect(draft.edits["Speaker 1"] == ConfirmedSpeaker(name: "Speaker 1", personId: nil))
    }

    @Test("Answering a speaker moves on to the next unreviewed one, wrapping around")
    func advancesToNextUnreviewed() {
        let draft = SpeakerReviewDraft(items: [item("Speaker 1"), item("Speaker 2"), item("Speaker 3")])
        draft.selectSpeaker("Speaker 2")
        draft.keepUnnamed()
        #expect(draft.selectedID == "Speaker 3")
        draft.search = "Cleo"
        draft.useTypedName()
        #expect(draft.selectedID == "Speaker 1")
        draft.assign(.init(id: "alex", name: "Alex", personId: "alex", detail: nil))
        #expect(draft.selectedID == "Speaker 1")
        #expect(draft.allReviewed)
    }

    @Test("Each answer and voice change is spoken, naming what happened and what is next")
    func announcesProgress() {
        let draft = SpeakerReviewDraft(items: [item("Speaker 1"), item("Speaker 2")])
        var spoken: [String] = []
        draft.announce = { spoken.append($0) }
        draft.assign(.init(id: "alex", name: "Alex", personId: "alex", detail: nil))
        draft.moveSelection(by: 1) // already on the last voice: nothing to say
        draft.moveSelection(by: -1)
        draft.selectSpeaker("Speaker 2")
        draft.keepUnnamed()
        #expect(spoken == [
            "Speaker 1 named Alex. Now Speaker 2, 1 voice left.",
            "Speaker 1, 1 of 2",
            "Speaker 2 kept unnamed. All voices reviewed. Press Return to confirm."
        ])
    }

    @Test("Voice scores rank attendees, and an attendee's library entry is not listed twice")
    func scoredAndCombined() {
        let library = VoiceLibrary(people: [
            .init(id: "alex", name: "Alex", voiceprints: [.init(embedding: [1, 0], model: "m", capturedAt: .now)]),
            .init(id: "bob", name: "Bob", voiceprints: [.init(embedding: [0, 1], model: "m", capturedAt: .now)]),
            .init(id: "cleo", name: "Cleo", voiceprints: [])
        ])
        let meeting = SpeakerReviewCandidates.meetingChoices(names: ["Alex", "Bob"], library: library,
                                                             search: "", clusterEmbedding: [0, 1])
        #expect(meeting.map(\.name) == ["Bob", "Alex"])
        #expect(meeting.first?.score == 1)
        let all = SpeakerReviewCandidates.combined(
            meeting: meeting,
            library: SpeakerReviewCandidates.libraryChoices(library: library, search: "", clusterEmbedding: [0, 1]))
        #expect(all.map(\.name) == ["Bob", "Alex", "Cleo"])
        #expect(all.last?.score == nil)
        #expect(!SpeakerReviewCandidates.offersTypedName("bob", among: all))
        #expect(SpeakerReviewCandidates.offersTypedName("Bobby", among: all))
    }

    @Test("Meeting names are normalized, searchable, and linked to a uniquely named library person")
    func meetingChoices() {
        let library = VoiceLibrary(people: [.init(id: "jaap", name: "Jaap Beekhuis", voiceprints: [])])
        let choices = SpeakerReviewCandidates.meetingChoices(
            names: ["Beekhuis, Jaap", "jaap beekhuis", " ", "Hidde de Vries"], library: library, search: " BEEK ")
        #expect(choices.count == 1)
        #expect(choices.first?.name == "Jaap Beekhuis")
        #expect(choices.first?.personId == "jaap")
    }

    @Test("Library search includes people without voiceprints and matches company names")
    func libraryChoices() {
        let library = VoiceLibrary(people: [
            .init(id: "alex", name: "Alex", company: "Acme", voiceprints: []),
            .init(id: "bob", name: "Bob", company: "Other", voiceprints: [])
        ])
        let choices = SpeakerReviewCandidates.libraryChoices(library: library, search: "ACME", clusterEmbedding: [])
        #expect(choices.map(\.personId) == ["alex"])
    }

    @Test("Ambiguous library names do not silently link a meeting attendee to the wrong person")
    func duplicateNames() {
        let library = VoiceLibrary(people: [
            .init(id: "alex-a", name: "Alex", company: "A", voiceprints: []),
            .init(id: "alex-b", name: "Alex", company: "B", voiceprints: [])
        ])
        let meeting = SpeakerReviewCandidates.meetingChoices(names: ["Alex"], library: library, search: "")
        #expect(meeting.first?.personId == nil)
        #expect(SpeakerReviewCandidates.libraryChoices(library: library, search: "Alex", clusterEmbedding: []).count == 2)
    }
}
