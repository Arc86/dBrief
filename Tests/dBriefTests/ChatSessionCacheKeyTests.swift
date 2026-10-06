import Testing
import dBriefWire

@Suite struct ChatSessionCacheKeyTests {
    let u1 = ChatTurnMessage(role: .user, content: "Q1"), a1 = ChatTurnMessage(role: .assistant, content: "A1")

    @Test func continuesWhenPromptAndUserTurnsMatch() {
        let cached = ChatSessionCacheKey(systemPrompt: "S", history: [u1, a1])
        #expect(cached.canContinue(systemPrompt: "S", history: [u1, a1]))
    }

    @Test func assistantTextDifferencesDoNotForceRebuild() {
        // The app may cut a reply short (ChatResponseLimiter); the session's KV holds the full reply.
        let cached = ChatSessionCacheKey(systemPrompt: "S", history: [u1, a1])
        #expect(cached.canContinue(systemPrompt: "S", history: [u1, .init(role: .assistant, content: "A1 (trimmed)")]))
    }

    @Test func rebuildsOnClearedHistoryChangedPromptOrEditedQuestion() {
        let cached = ChatSessionCacheKey(systemPrompt: "S", history: [u1, a1])
        #expect(!cached.canContinue(systemPrompt: "S", history: []))
        #expect(!cached.canContinue(systemPrompt: "S2", history: [u1, a1]))
        #expect(!cached.canContinue(systemPrompt: "S", history: [.init(role: .user, content: "Q1 edited"), a1]))
    }

    @Test func appendingATurnAdvancesTheKey() {
        var key = ChatSessionCacheKey(systemPrompt: "S", history: [])
        key.record(question: "Q1", answer: "A1")
        #expect(key.canContinue(systemPrompt: "S", history: [u1, a1]))
    }
}
