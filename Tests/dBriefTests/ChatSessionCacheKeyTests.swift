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

    @Test func continuesUnderTheGrowthCap() {
        var key = ChatSessionCacheKey(systemPrompt: "S", history: [])
        #expect(key.grownTokens == 0)
        key.record(question: "Q1", answer: "A1", extraTokens: 6_000)
        #expect(key.grownTokens == 6_000 + ChatEngineProfile.estimateTokens("Q1") + ChatEngineProfile.estimateTokens("A1"))
        #expect(key.canContinue(systemPrompt: "S", history: [u1, a1], incomingTokens: 6_000))
    }

    @Test func refusesOnceRecordedExcerptsPushItOverTheCap() {
        let cap = ChatSessionCacheKey.maxGrowthTokens
        var key = ChatSessionCacheKey(systemPrompt: "S", history: [])
        key.record(question: "Q1", answer: "A1", extraTokens: cap - 100)
        #expect(key.canContinue(systemPrompt: "S", history: [u1, a1], incomingTokens: 50))
        #expect(!key.canContinue(systemPrompt: "S", history: [u1, a1], incomingTokens: 200))
        #expect(key.exceedsCap(incomingTokens: 200))
    }

    @Test func aKeyRebuiltFromBareHistoryStartsAtZero() {
        var grown = ChatSessionCacheKey(systemPrompt: "S", history: [])
        grown.record(question: "Q1", answer: "A1", extraTokens: ChatSessionCacheKey.maxGrowthTokens)
        let rebuilt = ChatSessionCacheKey(systemPrompt: "S", history: [u1, a1])
        #expect(rebuilt.grownTokens == 0)
        #expect(rebuilt.canContinue(systemPrompt: "S", history: [u1, a1], incomingTokens: 6_000))
        #expect(!grown.canContinue(systemPrompt: "S", history: [u1, a1], incomingTokens: 6_000))
    }

    @Test func aHugeFullTranscriptPromptStillContinuesForSmallTurns() {
        // ~60K estimated tokens: a full-transcript system prompt must not count toward the cap.
        let transcript = String(repeating: "x", count: 180_000)
        #expect(ChatEngineProfile.estimateTokens(transcript) >= 60_000)
        var key = ChatSessionCacheKey(systemPrompt: transcript, history: [])
        key.record(question: "Q1", answer: "A1")
        #expect(key.canContinue(systemPrompt: transcript, history: [u1, a1], incomingTokens: 20))
    }
}
