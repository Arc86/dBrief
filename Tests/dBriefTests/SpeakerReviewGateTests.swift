import Testing
@testable import dBrief

struct SpeakerReviewGateTests {
    @Test("Optimistic never holds")
    func optimisticNeverHolds() {
        #expect(SpeakerReviewGate.shouldHold(mode: .optimistic, speakerCount: 5, libraryCount: 9) == false)
    }

    @Test("Confirm-first holds with >=2 speakers even with empty library")
    func holdsOnMultipleSpeakers() {
        #expect(SpeakerReviewGate.shouldHold(mode: .confirmFirst, speakerCount: 2, libraryCount: 0) == true)
    }

    @Test("Confirm-first holds with a non-empty library even with 1 speaker")
    func holdsOnLibrary() {
        #expect(SpeakerReviewGate.shouldHold(mode: .confirmFirst, speakerCount: 1, libraryCount: 1) == true)
    }

    @Test("Confirm-first does NOT hold for a solo speaker with empty library")
    func soloEmptyLibraryNoHold() {
        #expect(SpeakerReviewGate.shouldHold(mode: .confirmFirst, speakerCount: 1, libraryCount: 0) == false)
        #expect(SpeakerReviewGate.shouldHold(mode: .confirmFirst, speakerCount: 0, libraryCount: 0) == false)
    }
}
