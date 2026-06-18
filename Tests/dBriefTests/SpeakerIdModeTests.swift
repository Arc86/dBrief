import Testing
@testable import dBrief

struct SpeakerIdModeTests {
    @Test("Raw values are stable for persistence")
    func rawValues() {
        #expect(AppSettings.SpeakerIdMode.optimistic.rawValue == "optimistic")
        #expect(AppSettings.SpeakerIdMode.confirmFirst.rawValue == "confirmFirst")
        #expect(AppSettings.SpeakerIdMode(rawValue: "confirmFirst") == .confirmFirst)
    }

    @Test("Both modes have non-empty display copy")
    func displayCopy() {
        for mode in AppSettings.SpeakerIdMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(!mode.shortDescription.isEmpty)
        }
    }
}
