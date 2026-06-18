import Foundation
import Testing
@testable import dBrief

@Suite("AnalysisRoster")
struct AnalysisRosterTests {
    @Test("Joins participants and attendees, dedup case-insensitively, first-seen order")
    func joinsAndDedups() {
        let hint = AnalysisRoster.hint(
            participants: ["Alice", "Bob"],
            attendees: ["bob", "Carol"]
        )
        #expect(hint == "People likely in this meeting: Alice, Bob, Carol.")
    }

    @Test("Drops blanks and raw speaker placeholders")
    func dropsPlaceholders() {
        let hint = AnalysisRoster.hint(
            participants: ["  ", "Speaker 1", "speaker_2", "Dana"],
            attendees: []
        )
        #expect(hint == "People likely in this meeting: Dana.")
    }

    @Test("Returns nil when nothing usable")
    func nilWhenEmpty() {
        #expect(AnalysisRoster.hint(participants: [], attendees: []) == nil)
        #expect(AnalysisRoster.hint(participants: ["Speaker 3", "  "], attendees: []) == nil)
    }
}
