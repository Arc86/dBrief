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

    @Test func bulletedHeadingsStartASection() {
        let text = "- **Action Items:**\n- [Ann] to send the deck\n* DECISIONS:\n- Ship in May"
        #expect(ChunkNotesTextFormat.parse(text) == ChunkNotes(keyPoints: [], decisions: ["Ship in May"],
                                                               actionItems: ["[Ann] to send the deck"], people: []))
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

@Suite struct RefusalTextTests {
    @Test func recognisesShortApologies() {
        #expect(RefusalText.isRefusal("I apologize, but I cannot fulfill this request."))
        #expect(RefusalText.isRefusal("  I'm sorry, I can’t help with that."))
        #expect(RefusalText.isRefusal("Sorry, but I can't assist."))
    }

    @Test func keepsRealSummaries() {
        #expect(!RefusalText.isRefusal("The team agreed to move the Halcyon launch to March 14th."))
        #expect(!RefusalText.isRefusal("I cannot stress enough" + String(repeating: " how much the team discussed the launch plan", count: 6)))
        #expect(!RefusalText.isRefusal(""))
    }
}
