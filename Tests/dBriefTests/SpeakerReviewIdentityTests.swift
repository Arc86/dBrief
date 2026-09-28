import Testing
import dBriefWire
@testable import dBrief

struct SpeakerReviewIdentityTests {
    @Test(arguments: ["Alex", "Jesper Mol", "Speaker 1"])
    func authoritativeReviewClearsSuggestedIdentity(name: String) {
        let original = RichTranscript(segments: [], speakerLabels: [
            .init(id: "Speaker 1", displayName: "Jesper Mol", personId: "jesper")
        ])
        let output = SpeakerReassignment.confirm(original, speakerId: "Speaker 1",
                                                as: .init(name: name, personId: nil))
        #expect(output.speakerLabels.first?.displayName == name)
        #expect(output.speakerLabels.first?.personId == nil)
    }

    @Test func authoritativeReviewLinksTheSelectedPerson() {
        let original = RichTranscript(segments: [], speakerLabels: [
            .init(id: "Speaker 1", displayName: "Jesper Mol", personId: "jesper")
        ])
        let output = SpeakerReassignment.confirm(original, speakerId: "Speaker 1",
                                                as: .init(name: "Alex", personId: "alex"))
        #expect(output.speakerLabels.first?.displayName == "Alex")
        #expect(output.speakerLabels.first?.personId == "alex")
    }
}
