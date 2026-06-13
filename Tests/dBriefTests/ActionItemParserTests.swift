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

    @Test func sharedOwnerAppearsUnderEachGroup() {
        let groups = ActionItemParser.group(["[Alice/Bob] to review the draft"])
        #expect(groups.map(\.owner) == ["Alice", "Bob"])
        #expect(groups.allSatisfy { $0.items.count == 1 })
    }
}
