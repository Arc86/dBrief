import Testing
import dBriefWire

@Suite struct ChatContextPlannerTests {
    @Test func historyDropsPlaceholderAndCurrentQuestion() {
        let h = ChatContextPlanner.history(from: [
            (.user, "Q1"), (.assistant, "A1"), (.user, "Q2"), (.assistant, ""),
        ])
        #expect(h == [.init(role: .user, content: "Q1"), .init(role: .assistant, content: "A1")])
    }

    @Test func historyDropsUnansweredUserTurns() {
        // A stopped request leaves a user message with an empty answer that was removed.
        let h = ChatContextPlanner.history(from: [(.user, "Q1"), (.user, "Q2"), (.assistant, "A2"), (.user, "Q3")])
        #expect(h == [.init(role: .user, content: "Q2"), .init(role: .assistant, content: "A2")])
    }

    /// Mirrors `TranscriptChatService.sendInRecordingContext`: after appending the
    /// current user message and the empty assistant placeholder, `dropLast(2)` is
    /// applied before deriving history. (Tested on the pure function: the service
    /// needs a live model to run.)
    @Test func historyAsServiceDerivesIt() {
        let messages: [(role: ChatTurnMessage.Role, content: String)] = [
            (.user, "Q1"), (.assistant, "A1"), (.user, "Q2"), (.assistant, "A2"),
            (.user, "Q3"), (.assistant, ""),
        ]
        let h = ChatContextPlanner.history(from: Array(messages.dropLast(2)))
        #expect(h == [
            .init(role: .user, content: "Q1"), .init(role: .assistant, content: "A1"),
            .init(role: .user, content: "Q2"), .init(role: .assistant, content: "A2"),
        ])
        // First turn: nothing precedes the question.
        #expect(ChatContextPlanner.history(from: Array(messages.prefix(2).dropLast(2))).isEmpty)
    }
}
