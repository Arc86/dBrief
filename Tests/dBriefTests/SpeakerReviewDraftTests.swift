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
        draft.manualName = "  Alex de Jong \n"
        draft.useManualName()
        #expect(draft.edits["Speaker 1"] == ConfirmedSpeaker(name: "Alex de Jong", personId: nil))
        #expect(draft.reviewedIDs == ["Speaker 1"])
    }

    @Test("Switching speakers preserves assignments and clears the previous search and input")
    func independentAssignments() {
        let draft = SpeakerReviewDraft(items: [item("Speaker 1"), item("Speaker 2")])
        draft.assign(.init(id: "alex", name: "Alex", personId: "alex", detail: nil))
        draft.search = "Alex"
        draft.manualName = "Unsaved"
        draft.selectSpeaker("Speaker 2")
        #expect(draft.search.isEmpty)
        #expect(draft.manualName.isEmpty)
        draft.manualName = "Bob"
        draft.useManualName()
        #expect(draft.edits["Speaker 1"]?.personId == "alex")
        #expect(draft.edits["Speaker 2"] == ConfirmedSpeaker(name: "Bob", personId: nil))
    }

    @Test("Keeping a label removes a suggested library identity; blank manual input leaves it intact")
    func keepUnnamed() {
        let draft = SpeakerReviewDraft(items: [item("Speaker 1", name: "Jesper Mol", personID: "jesper")])
        draft.manualName = " \n "
        draft.useManualName()
        #expect(draft.edits["Speaker 1"]?.personId == "jesper")
        draft.keepUnnamed()
        #expect(draft.edits["Speaker 1"] == ConfirmedSpeaker(name: "Speaker 1", personId: nil))
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
