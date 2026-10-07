import Testing
import dBriefWire

@Suite struct EmbeddingPromptTests {
    @Test func usesEmbeddingGemmaTaskPrefixes() {
        let gemma = EmbeddingModelSpec.embeddingGemma300m4bit
        #expect(EmbeddingPrompt.format("when is launch", role: .query, spec: gemma) == "task: search result | query: when is launch")
        #expect(EmbeddingPrompt.format("[00:01:00] A: hi", role: .document, spec: gemma) == "title: none | text: [00:01:00] A: hi")
    }

    @Test func usesE5PrefixesAndBgeM3HasNone() {
        #expect(EmbeddingPrompt.format("q", role: .query, spec: .multilingualE5Small) == "query: q")
        #expect(EmbeddingPrompt.format("d", role: .document, spec: .multilingualE5Small) == "passage: d")
        #expect(EmbeddingPrompt.format("q", role: .query, spec: .bgeM3) == "q")
        #expect(EmbeddingPrompt.format("d", role: .document, spec: .bgeM3) == "d")
    }

    @Test func defaultFormatUsesCurrentModel() {
        #expect(EmbeddingPrompt.format("x", role: .query) == EmbeddingPrompt.current.queryPrefix + "x")
        #expect(EmbeddingPrompt.format("x", role: .document) == EmbeddingPrompt.current.documentPrefix + "x")
        #expect(EmbeddingPrompt.modelID == EmbeddingPrompt.current.id)
    }

    @Test func lookupFindsKnownModelsOnly() {
        #expect(EmbeddingModelSpec.named("intfloat/multilingual-e5-small") == .multilingualE5Small)
        #expect(EmbeddingModelSpec.named(EmbeddingPrompt.current.id) == EmbeddingPrompt.current)
        #expect(EmbeddingModelSpec.named("nope/unknown") == nil)
        #expect(EmbeddingModelSpec.named(EmbeddingModelSpec.bgeM3.id) == nil) // can't load: no root safetensors
    }
}
