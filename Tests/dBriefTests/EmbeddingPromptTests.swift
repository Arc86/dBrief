import Testing
import dBriefWire

@Suite struct EmbeddingPromptTests {
    @Test func usesEmbeddingGemmaTaskPrefixes() {
        #expect(EmbeddingPrompt.format("when is launch", role: .query) == "task: search result | query: when is launch")
        #expect(EmbeddingPrompt.format("[00:01:00] A: hi", role: .document) == "title: none | text: [00:01:00] A: hi")
    }
}
