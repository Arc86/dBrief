import Foundation
import Testing
@testable import dBrief

@Suite("Voice library table helpers")
struct VoiceLibraryTableTests {
    private func person(_ name: String, company: String? = nil, _ prints: [(TimeInterval, [Float])]) -> KnownPerson {
        KnownPerson(id: name.lowercased(), name: name, company: company,
                    voiceprints: prints.map { Voiceprint(embedding: $0.1, model: "t", capturedAt: Date(timeIntervalSince1970: $0.0)) })
    }

    private func person(_ name: String, company: String? = nil, times: [TimeInterval]) -> KnownPerson {
        person(name, company: company, times.map { ($0, [1, 0]) })
    }

    @Test("firstHeard returns the oldest capture, nil when empty")
    func firstHeard() {
        #expect(VoiceLibraryDisplay.firstHeard(person("A", times: [5, 2, 9])) == Date(timeIntervalSince1970: 2))
        #expect(VoiceLibraryDisplay.firstHeard(person("B", times: [])) == nil)
    }

    @Test("Strength is weak below two voiceprints, good at two, strong from three")
    func strength() {
        #expect(VoiceLibraryDisplay.strength(person("A", times: [])) == .weak)
        #expect(VoiceLibraryDisplay.strength(person("A", times: [1])) == .weak)
        #expect(VoiceLibraryDisplay.strength(person("A", times: [1, 2])) == .good)
        #expect(VoiceLibraryDisplay.strength(person("A", times: [1, 2, 3, 4, 5])) == .strong)
    }

    @Test("Initials take the first and last word, skipping Dutch infixes naturally")
    func initials() {
        #expect(VoiceLibraryDisplay.initials("Arjan van Laar") == "AL")
        #expect(VoiceLibraryDisplay.initials("Wouter van den Heuvel") == "WH")
        #expect(VoiceLibraryDisplay.initials("  madonna ") == "M")
        #expect(VoiceLibraryDisplay.initials("") == "?")
    }

    @Test("Avatar colour index is stable for a key and stays in range")
    func avatarIndex() {
        let a = VoiceLibraryDisplay.avatarIndex(for: "Amsterdam UMC", count: 6)
        #expect(a == VoiceLibraryDisplay.avatarIndex(for: "Amsterdam UMC", count: 6))
        #expect((0..<6).contains(a))
        #expect(VoiceLibraryDisplay.avatarIndex(for: "", count: 6) == 0)
    }

    @Test("Merge survivor has the most voiceprints, then the newest, then the name")
    func mergeSurvivor() {
        let few = person("Few", times: [100])
        let many = person("Many", times: [1, 2])
        #expect(VoiceLibraryDisplay.mergeSurvivor([few, many])?.id == many.id)

        let older = person("Older", times: [1, 2])
        let newer = person("Newer", times: [1, 50])
        #expect(VoiceLibraryDisplay.mergeSurvivor([older, newer])?.id == newer.id)

        let b = person("Bea", times: [1])
        let a = person("Ann", times: [1])
        #expect(VoiceLibraryDisplay.mergeSurvivor([b, a])?.id == a.id)
        #expect(VoiceLibraryDisplay.mergeSurvivor([]) == nil)
    }

    @Test("Voice similarity is the best match across both people's voiceprints")
    func voiceSimilarity() throws {
        let a = person("A", [(1, [1, 0]), (2, [0, 1])])
        let b = person("B", [(1, [0.6, 0.8])])
        let similarity = try #require(VoiceLibraryDisplay.voiceSimilarity(a, b))
        #expect(abs(similarity - 0.8) < 0.0001)
        #expect(VoiceLibraryDisplay.voiceSimilarity(a, person("Empty", [])) == nil)
    }

    @Test("Selection similarity is the weakest pair, nil below two people")
    func selectionSimilarity() {
        let a = person("A", [(1, [1, 0])])
        let b = person("B", [(1, [1, 0])])
        let c = person("C", [(1, [0, 1])])
        #expect(VoiceLibraryDisplay.selectionSimilarity([a]) == nil)
        #expect(VoiceLibraryDisplay.selectionSimilarity([a, b]).map { abs($0 - 1) < 0.0001 } == true)
        #expect(VoiceLibraryDisplay.selectionSimilarity([a, b, c]).map { abs($0) < 0.0001 } == true)
        #expect(VoiceLibraryDisplay.selectionSimilarity([a, person("Empty", [])]) == nil)
    }

    @Test("Rows carry sort keys that order people without voiceprints last")
    func rows() {
        let row = VoiceLibraryRow(person("Arjan", company: " Amsterdam UMC ", times: [3, 8]))
        #expect(row.company == "Amsterdam UMC")
        #expect(row.voiceprintCount == 2)
        #expect(row.firstHeard == Date(timeIntervalSince1970: 3))
        #expect(row.lastHeard == Date(timeIntervalSince1970: 8))

        let empty = VoiceLibraryRow(person("Nobody", company: "  ", times: []))
        #expect(empty.company == nil)
        #expect(empty.lastHeardKey < row.lastHeardKey)
        #expect(empty.companyKey > row.companyKey)
    }
}

@Suite("Voice library table sorting and selection")
struct VoiceLibraryTableInteractionTests {
    private func row(_ name: String, company: String? = nil, times: [TimeInterval]) -> VoiceLibraryRow {
        VoiceLibraryRow(KnownPerson(id: name.lowercased(), name: name, company: company,
                                    voiceprints: times.map { Voiceprint(embedding: [1], model: "t", capturedAt: Date(timeIntervalSince1970: $0)) }))
    }

    @Test("Sorting follows the column and direction, with name as the tiebreak")
    func sorting() {
        let rows = [row("Bea", company: "Zeta", times: [5]), row("Ann", company: "Acme", times: [5, 6]),
                    row("Cas", times: [1])]
        #expect(VoiceLibraryRow.sorted(rows, by: .name, ascending: true).map(\.name) == ["Ann", "Bea", "Cas"])
        #expect(VoiceLibraryRow.sorted(rows, by: .company, ascending: true).map(\.name) == ["Ann", "Bea", "Cas"])
        #expect(VoiceLibraryRow.sorted(rows, by: .voiceprints, ascending: false).map(\.name) == ["Ann", "Bea", "Cas"])
        #expect(VoiceLibraryRow.sorted(rows, by: .lastHeard, ascending: false).map(\.name) == ["Ann", "Bea", "Cas"])
        #expect(VoiceLibraryRow.sorted(rows, by: .firstHeard, ascending: true).map(\.name) == ["Cas", "Ann", "Bea"])
    }

    @Test("Text columns start ascending, counts and dates start newest or largest first")
    func defaultDirection() {
        #expect(VoiceLibraryRow.Column.name.startsAscending)
        #expect(VoiceLibraryRow.Column.company.startsAscending)
        #expect(!VoiceLibraryRow.Column.voiceprints.startsAscending)
        #expect(!VoiceLibraryRow.Column.lastHeard.startsAscending)
    }

    private let order = ["a", "b", "c", "d"]

    @Test("A plain click selects one row and sets the anchor")
    func plainClick() {
        let s = VoiceLibrarySelection.click("c", order: order, current: ["a", "b"], anchor: "a", command: false, shift: false)
        #expect(s.selection == ["c"])
        #expect(s.anchor == "c")
    }

    @Test("Command-click toggles a row")
    func commandClick() {
        var s = VoiceLibrarySelection.click("c", order: order, current: ["a"], anchor: "a", command: true, shift: false)
        #expect(s.selection == ["a", "c"])
        s = VoiceLibrarySelection.click("a", order: order, current: s.selection, anchor: s.anchor, command: true, shift: false)
        #expect(s.selection == ["c"])
    }

    @Test("Shift-click selects the range from the anchor, in either direction")
    func shiftClick() {
        #expect(VoiceLibrarySelection.click("d", order: order, current: ["b"], anchor: "b", command: false, shift: true).selection == ["b", "c", "d"])
        #expect(VoiceLibrarySelection.click("a", order: order, current: ["c"], anchor: "c", command: false, shift: true).selection == ["a", "b", "c"])
        // No anchor visible: behaves like a plain click.
        #expect(VoiceLibrarySelection.click("b", order: order, current: [], anchor: "zz", command: false, shift: true).selection == ["b"])
    }

    @Test("Arrow keys move a single selection and stop at the ends")
    func arrows() {
        #expect(VoiceLibrarySelection.move(by: 1, order: order, current: ["b"]) == "c")
        #expect(VoiceLibrarySelection.move(by: -1, order: order, current: ["a"]) == "a")
        #expect(VoiceLibrarySelection.move(by: 1, order: order, current: ["d"]) == "d")
        #expect(VoiceLibrarySelection.move(by: 1, order: order, current: []) == "a")
        #expect(VoiceLibrarySelection.move(by: -1, order: order, current: ["b", "d"]) == "a")
        #expect(VoiceLibrarySelection.move(by: 1, order: [], current: []) == nil)
    }
}
