import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon

/// Grammar-constrained JSON generation (xgrammar via MLXGuidedGeneration): the
/// output always parses against `schema`. Sampling is greedy by construction (F7).
enum GuidedJSONGenerator {
    /// Thrown when guided generation failed before emitting anything, so the caller
    /// may safely fall back to free-text generation without corrupting a stream.
    struct FailedBeforeOutput: Error { let underlying: Error }

    struct Output: Sendable {
        let json: String
        /// Generation reached the closing zones near `maxTokens`, so the JSON was
        /// closed early and its last list may be truncated.
        let closedAtCap: Bool
    }

    static func generate(
        system: String,
        user: String,
        schema: String,
        maxTokens: Int,
        container: ModelContainer,
        onDelta: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Output {
        try await container.perform { context in
            let tokenizer = context.tokenizer
            var output = ""
            var closedAtCap = false
            do {
                let vocab = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
                let grammarTokenizer = try GrammarTokenizer(
                    vocab: vocab.vocab, vocabType: vocab.vocabType,
                    eosTokenId: Int32(tokenizer.eosTokenId ?? 0))
                let constraint = try GrammarConstraint(
                    tokenizer: grammarTokenizer, jsonSchema: schema,
                    fastForward: true, hostTokenizer: tokenizer)
                let input = try await context.processor.prepare(
                    input: UserInput(chat: [.system(system), .user(user)]))
                let estimate = CompletionReserve.estimate(schemaJSON: schema, tokenizer: tokenizer)
                let completionReserve = max(estimate, GemmaGenerationConfig.minCompletionReserve)
                let generated = try GuidedGenerationLoop.run(
                    input: input,
                    context: context,
                    constraint: constraint,
                    maxTokens: maxTokens,
                    vocabSize: grammarTokenizer.vocabSize,
                    kvCache: GemmaGenerationConfig.kvCache,
                    completionReserve: completionReserve,
                    hardReserve: max(estimate * 2, GemmaGenerationConfig.minHardReserve),
                    closingBias: ClosingTokenBias.compute(tokenizer: tokenizer, eosTokenId: tokenizer.eosTokenId),
                    prefill: .init(stepSize: 256)
                ) { delta in
                    output += delta
                    onDelta(delta)
                    return true
                }
                closedAtCap = generated >= maxTokens - completionReserve
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if output.isEmpty { throw FailedBeforeOutput(underlying: error) }
                throw error
            }
            return Output(json: output, closedAtCap: closedAtCap)
        }
    }
}
