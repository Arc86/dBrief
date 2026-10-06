import Testing
import dBriefWire

@Suite struct ChunkNotesTextFormatTests {
    @Test func parsesTheRequestedSections() {
        let text = """
        ACTION ITEMS:
        - [Priya] to share the runbook next Monday
        - [Marisol] to send the contract to legal

        DECISIONS:
        - Launch moves to March 14th
        PEOPLE:
        - Priya
        - Marisol
        KEY POINTS:
        1. Budget is tight this quarter.
        2) Vendor lock-in worries customers.
        """
        #expect(ChunkNotesTextFormat.parse(text) == ChunkNotes(
            keyPoints: ["Budget is tight this quarter.", "Vendor lock-in worries customers."],
            decisions: ["Launch moves to March 14th"],
            actionItems: ["[Priya] to share the runbook next Monday", "[Marisol] to send the contract to legal"],
            people: ["Priya", "Marisol"]))
    }

    @Test func toleratesMarkdownAndSnakeCaseHeadingsAndInlineItems() throws {
        let text = """
        **action_items:**
        * [Dewitt] to book the room
        ## Decisions
        • Keep the current format
        **key_points:** Customers doubt the platform's breadth.
        """
        let notes = try #require(ChunkNotesTextFormat.parse(text))
        #expect(notes.actionItems == ["[Dewitt] to book the room"])
        #expect(notes.decisions == ["Keep the current format"])
        #expect(notes.keyPoints == ["Customers doubt the platform's breadth."])
        #expect(notes.people.isEmpty)
    }

    @Test func ignoresTextBeforeTheFirstHeadingAndDeduplicates() {
        let text = "Here are the notes.\nPEOPLE:\n- Ian\n- Ian\nKEY POINTS:\n- x"
        #expect(ChunkNotesTextFormat.parse(text) == ChunkNotes(keyPoints: ["x"], decisions: [], actionItems: [], people: ["Ian"]))
    }

    @Test func textWithoutAnyHeadingIsNotNotes() {
        #expect(ChunkNotesTextFormat.parse("I apologize, but I cannot fulfill this request.") == nil)
        #expect(ChunkNotesTextFormat.parse("PEOPLE:\n") == ChunkNotes(keyPoints: [], decisions: [], actionItems: [], people: []))
    }

    @Test func instructionNamesEveryHeading() {
        for heading in ["ACTION ITEMS:", "DECISIONS:", "PEOPLE:", "KEY POINTS:"] {
            #expect(ChunkNotesTextFormat.instruction.contains(heading))
        }
    }
}
