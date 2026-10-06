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

    static let maxOutputTokens = 8192

    // Long-transcript strategy (Task 7). Token counts from Gemma's own tokenizer.
    static let singlePassTokenBudget = 24_000
    static let chunkTokenBudget = 10_000
    static let reduceInputTokenBudget = 12_000
    static let chunkOverlapLines = 2
}
