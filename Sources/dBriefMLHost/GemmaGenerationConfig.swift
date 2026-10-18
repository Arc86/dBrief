import MLXLMCommon

/// Single home for local-Gemma tuning. Values are tuned with scripts/gemma-eval.py;
/// the measurements behind them are in the commit messages.
enum GemmaGenerationConfig {
    /// TurboQuant on Gemma 4's global-attention layers (the only layers whose cache
    /// grows; the 512-token sliding layers stay fp16). `.balanced` (fp8 keys + 3-bit
    /// values, turbo8v3) showed no recall/repetition regression versus both fp16 and
    /// `.qualityFirst` on the M/L eval (see commit message); it is the most compressed
    /// preset that held up.
    static let kvCache = KVCacheConfiguration(
        strategy: .turboQuant(.balanced),
        compatibility: .allowPartial)

    /// Output cap for the single-pass unified insights call.
    static let maxOutputTokens = 8192
    /// Output caps for map-reduce: notes for one ~4K-token part, and the final reduce.
    static let chunkNotesMaxTokens = 2048
    static let reduceMaxTokens = 4096

    /// Guided closure zones, floors on top of `CompletionReserve.estimate`. The hard
    /// zone must fit closing a mid-list string plus every remaining required key; at
    /// 32 tokens a runaway list hit the cap unclosed and threw `incompleteOutput`.
    static let minCompletionReserve = 512
    static let minHardReserve = 192

    // Long-transcript strategy. Token counts from Gemma's own tokenizer. Tuned on the
    // planted-needle eval (recall of 3 needles at 10/50/90%): on a ~24K-token
    // transcript single pass recalled 1/3, map-reduce 2/3 (so map-reduce starts at 8K);
    // on ~55K tokens 10K parts recalled 1/3 in 401 s, 6K parts 1/3 in 667 s, 4K parts 2/3 in 679 s.
    static let singlePassTokenBudget = 8_000
    static let chunkTokenBudget = 4_000
    /// Largest prompt Gemma handled comfortably in the earlier single-pass eval; the
    /// reduce prompt (notes) must stay within it.
    static let maxPromptTokens = 24_000
    static let reduceInputTokenBudget = 12_000
    static let chunkOverlapLines = 2
}
