import Testing
@testable import dBrief

@Suite("Action item owner parsing")
struct ActionItemParserTests {

    @Test func parsesLeadingOwnerAndStripsTo() {
        let items = ActionItemParser.parse("[Alice] to send the report by Friday")
        #expect(items.count == 1)
        #expect(items[0].owner == "Alice")
        #expect(items[0].text == "send the report by Friday")
        #expect(items[0].raw == "[Alice] to send the report by Friday")
    }

    @Test func unassignedWhenNoBracket() {
        let items = ActionItemParser.parse("Follow up with the client")
        #expect(items.count == 1)
        #expect(items[0].owner == nil)
        #expect(items[0].text == "Follow up with the client")
    }

    @Test func sharedOwnerSplitsIntoOneEntryPerPerson() {
        let items = ActionItemParser.parse("[Alice/Bob] to review the draft")
        #expect(items.count == 2)
        #expect(items.map(\.owner) == ["Alice", "Bob"])
        #expect(items.allSatisfy { $0.text == "review the draft" })
        // Shared items keep the same raw so completion state stays consistent.
        #expect(items[0].raw == items[1].raw)
    }

    @Test func sharedOwnerHandlesAndAndComma() {
        #expect(ActionItemParser.parse("[Alice and Bob] to ship it").map(\.owner) == ["Alice", "Bob"])
        #expect(ActionItemParser.parse("[Alice, Bob & Carol] to ship it").map(\.owner) == ["Alice", "Bob", "Carol"])
    }

    @Test func groupingPreservesOwnerOrderAndTrailingUnassigned() {
        let groups = ActionItemParser.group([
            "[Bob] to draft the spec",
            "Schedule the kickoff",
            "[Alice] to review",
            "[Bob] to deploy",
        ])
        #expect(groups.map(\.owner) == ["Bob", "Alice", ActionItemGroup.unassignedLabel])
        #expect(groups[0].items.count == 2)        // Bob
        #expect(groups[1].items.count == 1)        // Alice
        #expect(groups.last?.isUnassigned == true)
        #expect(groups.last?.items.count == 1)
    }

    @Test func sharedTaskAppearsOnceWithBothOwners() {
        let raw = "[Hidde 1/Jesper 2] Seismic pagina opleveren voor vrijdag"
        let groups = ActionItemParser.group([raw])
        #expect(groups.map(\.owner) == ["Hidde & Jesper"])
        #expect(groups.flatMap(\.items).count == 1)
        #expect(groups.first?.items.first?.raw == raw)
        #expect(groups.first?.items.first?.text == "Seismic pagina opleveren voor vrijdag")
    }

    @Test func numberedAndCleanNamesUseTheSameCard() {
        let groups = ActionItemParser.group([
            "[Hidde 1/Jesper 2] review version 2", "[Jesper/Hidde] send version 3",
            "[Hidde 1] prepare", "[Hidde] finish",
        ])
        #expect(groups.map(\.owner) == ["Hidde & Jesper", "Hidde"])
        #expect(groups.first?.owners == ["Hidde", "Jesper"])
        #expect(groups.map { $0.items.count } == [2, 2])
        #expect(groups.first?.items.first?.text == "review version 2")
    }

    @Test func unnamedSpeakerNumbersRemainDistinct() {
        let groups = ActionItemParser.group(["[Speaker 1/Speaker 2] review"])
        #expect(groups.first?.owners == ["Speaker 1", "Speaker 2"])
    }

    @Test func sharedGroupsKeepIndividualTasksSeparateAndIgnoreOwnerOrder() {
        let groups = ActionItemParser.group([
            "[Alice] to draft", "[Alice/Bob] to review", "[Bob & Alice] to ship", "[Bob] to deploy",
        ])
        #expect(groups.map(\.owner) == ["Alice", "Alice & Bob", "Bob"])
        #expect(groups.map { $0.items.count } == [1, 2, 1])
    }

    @Test func repeatedSharedOwnerDoesNotCreateAnotherCard() {
        let groups = ActionItemParser.group(["[Alice/Alice] to review"])
        #expect(groups.map(\.owner) == ["Alice"])
        #expect(groups.flatMap(\.items).count == 1)
    }

    @Test func groupsNaturalLanguageOwnersFromMeetingRoster() {
        let groups = ActionItemParser.group([
            "Jesper de Service Operations-slides afronden",
            "Hidde de business value map uitwerken",
            "Hidde en Jesper valideren samen de intro",
        ], knownOwners: ["Jesper Mol", "Hidde Janssen"])
        #expect(groups.map(\.owner) == ["Jesper", "Hidde", "Hidde & Jesper"])
        #expect(groups[0].items.count == 1)
        #expect(groups[1].items.count == 1)
        #expect(groups[2].items.count == 1)
        #expect(groups[0].items[0].text == "de Service Operations-slides afronden")
        #expect(groups.last?.items.first?.text == "valideren samen de intro")
    }

    @Test func doesNotGuessUnknownOrAmbiguousNames() {
        #expect(ActionItemParser.parse("Review the slides", knownOwners: ["Jesper Mol"])[0].owner == nil)
        #expect(ActionItemParser.parse("Ann de slides maken", knownOwners: ["Ann Smith", "Ann Jones"])[0].owner == nil)
    }

    @Test func repeatedRosterNameStillMatchesFirstName() {
        let item = ActionItemParser.parse("Jesper de slides afronden", knownOwners: ["Jesper Mol", "Jesper Mol"])
        #expect(item[0].owner == "Jesper")
    }
}
