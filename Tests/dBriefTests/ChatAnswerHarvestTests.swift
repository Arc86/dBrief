import Foundation
import Testing
@testable import dBrief

@Suite("Chat answer harvest")
struct ChatAnswerHarvestTests {
    private let known = ["Vera Elsen", "Maarten van Egmond", "Jesper Mol"]

    @Test("List lines become action items; known-person labels set the owner")
    func actionItemsWithOwners() {
        let answer = """
        ## Actiepunten
        Vera Elsen
        - **Blueprint maken** voor risk [00:00:00]
        - Chris benaderen [00:00:59] / [00:07:15]
        Maarten + Jesper (impliciet):
        1. Vervolgsessie plannen:
        Open / niet-toegewezen punten
        • Deadline eind 2027 bewaken
        """
        let items = ChatAnswerHarvest.actionItems(from: answer, knownOwners: known)
        #expect(items == [
            "[Vera Elsen] Blueprint maken voor risk",
            "[Vera Elsen] Chris benaderen",
            "[Maarten van Egmond/Jesper Mol] Vervolgsessie plannen",
            "Deadline eind 2027 bewaken",
        ])
        let parsed = ActionItemParser.parse(items[2])
        #expect(parsed.compactMap(\.owner) == ["Maarten van Egmond", "Jesper Mol"])
    }

    @Test("Duplicates and fragments are dropped")
    func actionItemDedupe() {
        let items = ChatAnswerHarvest.actionItems(from: "- Send deck\n- send deck\n- ok", knownOwners: [])
        #expect(items == ["Send deck"])
    }

    @Test("A summary addition is its own section with demoted headings")
    func summaryAddition() {
        let result = ChatAnswerHarvest.summary("Existing summary.", adding: "## Decisions\n---\n- Ship it",
                                               question: ChatPromptTemplate.decisions.prompt)
        #expect(result == "Existing summary.\n\n### Decisions\n\n#### Decisions\n- Ship it")
        #expect(ChatAnswerHarvest.sectionTitle(for: nil) == "From Ask dBrief")
    }

    @Test("Conversation export skips errors and unanswered questions")
    func conversation() {
        let messages = [
            ChatMessage(role: .user, content: "First?"),
            ChatMessage(role: .assistant, content: "<think>hmm</think>Answer one"),
            ChatMessage(role: .user, content: "Second?"),
            ChatMessage(role: .assistant, content: "Error: offline"),
            ChatMessage(role: .user, content: "Third?"),
        ]
        #expect(ChatAnswerHarvest.conversationBody(messages) == "### First?\n\nAnswer one")
        #expect(ChatAnswerHarvest.conversationDocument(messages, title: "Sync")
                    .hasPrefix("# Ask dBrief: Sync\n\n### First?"))
    }

    @Test("The Ask dBrief note section goes before the transcript and is replaced later")
    func noteSection() {
        let note = "# Title\n\n## 📝 Summary\n\nText\n\n## 💬 Transcript\n\nHello"
        let first = MarkdownInsightsUpdater.upsertAskDBrief(markdown: note, body: "### Q\n\nA")
        #expect(first == "# Title\n\n## 📝 Summary\n\nText\n\n## ✨ Ask dBrief\n\n### Q\n\nA\n\n## 💬 Transcript\n\nHello")
        let second = MarkdownInsightsUpdater.upsertAskDBrief(markdown: first, body: "### Q2\n\nB")
        #expect(second == "# Title\n\n## 📝 Summary\n\nText\n\n## ✨ Ask dBrief\n\n### Q2\n\nB\n\n## 💬 Transcript\n\nHello")
        #expect(MarkdownInsightsUpdater.upsertAskDBrief(markdown: "# T\n", body: "x") == "# T\n\n## ✨ Ask dBrief\n\nx\n")
    }

    @Test("Follow-ups put saved prompts first, then one person, then built-ins")
    func followUpOrder() {
        let saved = [SavedChatPrompt(title: "Risks", prompt: "What are the risks?")]
        let titles = ChatPromptTemplate.followUps(after: [], people: ["Vera Elsen"], saved: saved, limit: 4).map(\.title)
        #expect(titles == ["Risks", "What did Vera commit to?", "Summarize", "Action items"])
    }

    @Test("Saved prompt titles keep whole words")
    func savedTitle() {
        #expect(SavedChatPrompt.title(for: "Short one") == "Short one")
        #expect(SavedChatPrompt.title(for: "What were the main risks raised by the customer today?") == "What were the main risks…")
        #expect(AnalysisRoster.names(participants: ["Ann", "ann", "Speaker 1"], attendees: ["Bob"]) == ["Ann", "Bob"])
    }
}
