# Apple Intelligence Guided-Generation Upgrade — Design

**Date:** 2026-06-09
**Branch (to create):** `feat/apple-intelligence-guided-generation`
**Status:** Approved design, pending implementation plan

## Background

dBrief's Apple Intelligence backend (`Sources/dBrief/Services/LocalAIService.swift`)
uses the macOS 26 `FoundationModels` framework — the only API surface for Apple's
on-device LLM (the framework did not exist before macOS 26, so there is no older
version to migrate from). However, it uses the framework in its most basic mode:

- 4 separate `LanguageModelSession` calls (`generateSummary`, `extractActionItems`,
  `analyzeTags`, `generateTitle`).
- Free-form text output parsed by hand: `analyzeTags` runs `JSONSerialization` and
  silently falls back to `tags: []` / `sentiment: "neutral"` on any malformed output;
  `extractActionItems` splits on newlines, regex-strips bullets, and drops items
  shorter than 6 characters.
- No `GenerationOptions`, no `prewarm()`, and a single generic availability message.

Meanwhile the Gemma (MLX) and Local-CLI engines already share one **unified** call
that returns a single `LocalInsightsResult` against `UnifiedInsightsPrompt`
(`Sources/dBriefWire/`).

## Goal

Adopt the macOS 26 best-practice **guided generation** (`@Generable` / `@Guide`) for
the Apple Intelligence insights path, unify it into a single model call matching the
existing Gemma/Local-CLI contract, and apply adjacent tuning (GenerationOptions,
prewarm, richer availability messaging, chat-path tuning).

### Expected output-quality impact

The primary win is **reliability and consistency, not raw model intelligence**:

- **Eliminates silent data loss** — constrained decoding guarantees a valid struct,
  so tags/sentiment can no longer vanish to empty/`neutral` on malformed JSON.
- **Cleaner action items** — typed `[String]`, no markdown artifacts, no filler
  leakage, no length-heuristic dropping legitimate short items.
- **Guaranteed-valid sentiment** via an enum.
- **Cross-engine consistency** — same output shape as Gemma/Local-CLI.
- **Modest accuracy bump** from low temperature on extraction.

Summary *prose* quality is unchanged (that is the on-device model's ceiling).

## Decisions (from brainstorming)

1. **Call structure:** Unify into one call (matches Gemma/Local-CLI). Trade-offs
   accepted: the three separately customizable prompts
   (`effectiveSummaryPrompt` / `effectiveActionItemsPrompt` / `effectiveTagsPrompt`)
   stop applying to Apple Intelligence, and the 3 progress steps collapse to 1.
2. **In scope:** guided-generation conversion + GenerationOptions tuning +
   better availability messaging + chat-path tuning + prewarm.

## Architecture

### LocalAIService (rewrite)

Replace the 4 public methods with one, returning the existing shared type so
downstream code (sidecars, markdown, history) is unchanged:

```swift
func analyzeTranscript(_ transcription: String, outputLanguage: OutputLanguage)
    async throws -> LocalInsightsResult
```

Internally:
- Build the system prompt via the new
  `UnifiedInsightsPrompt.systemPromptForGuidedGeneration(outputLanguage:)`.
- Truncate the transcript with a FoundationModels-specific budget (see below).
- `let session = LanguageModelSession(instructions: systemPrompt)`
- `let result = try await session.respond(to: userPrompt, generating: MeetingInsights.self, options: options)`
- Map `MeetingInsights` → `LocalInsightsResult`.

`prewarm()` exposed/called when AI processing begins.

### @Generable schema

```swift
@available(macOS 26, *)
@Generable
struct MeetingInsights {
    @Guide(description: "Thorough multi-paragraph summary covering all major topics; specific names, projects, tools, deadlines.")
    var summary: String

    @Guide(description: "Every action item, format '[WHO] to [TASK] [CONTEXT/DEADLINE]'.")
    var actionItems: [String]

    @Guide(description: "5–10 single-word topic tags.")
    var tags: [String]

    var sentiment: Sentiment

    @Guide(description: "Short 3–6 word descriptive title.")
    var titleConcept: String
}

@available(macOS 26, *)
@Generable
enum Sentiment: String { case positive, neutral, negative }
```

`Sentiment` maps to the capitalized strings (`"Positive"` / `"Neutral"` /
`"Negative"`) that `LocalInsightsResult` and markdown already expect.

### RecordingManager wiring

Add `runAppleIntelligenceUnifiedTasks(...)` modeled on `runLocalQwenTasks`
(RecordingManager.swift:1086): one call populating summary, action items, tags,
sentiment, and the inline title. Remove the old `runAppleIntelligenceTasks` and the
two separate Apple-Intelligence title-generation calls (RecordingManager.swift:358
and :562) — title now comes from the unified result, exactly as the Gemma path
already skips the separate title step.

### Prompt reuse (dBriefWire, shared)

Refactor `UnifiedInsightsPrompt` to split rules from the JSON-format block:
- New `systemPromptForGuidedGeneration(outputLanguage:)` — rules **without** the
  "OUTPUT FORMAT (Strict JSON Only)" section (guided generation injects the schema;
  restating JSON would conflict).
- Existing `systemPrompt(outputLanguage:)` retained for Gemma/CLI, recomposed from
  the same shared rules string + the JSON block.

All engines continue reading one rule set, kept in lockstep.

### Context-window budget (correctness)

FoundationModels has a ~4096-token window — far smaller than Gemma's 128K. Reusing
`UnifiedInsightsPrompt.truncate` (100K chars) would overflow it. Apple Intelligence
keeps its **own** tight budget (~12K chars head/tail, as today) via a dedicated
`truncateForFoundationModels(...)`. `GenerationOptions(temperature: 0.3)` plus a
`maximumResponseTokens` ceiling sized to leave window headroom.

### Availability messaging

A pure mapping from `SystemLanguageModel.default.availability` to specific messages:
- `.available` → proceed
- `.unavailable(.deviceNotEligible)` → device-not-eligible message
- `.unavailable(.appleIntelligenceNotEnabled)` → enable-Apple-Intelligence message
- `.unavailable(.modelNotReady)` → model-downloading/not-ready message
- default → generic fallback

Surfaced through the existing `markFailed(...)` step UI.

### Chat path tuning

`TranscriptChatService` Apple Intelligence streaming path gains `prewarm()` (on chat
view open) and `GenerationOptions`. Output stays free-form (no schema — guided
generation does not apply to open-ended Q&A).

### Error handling

Map `LanguageModelSession` errors (context-window-exceeded, guardrail/safety,
unsupported-language) to clear `LocalizedError` messages via `markFailed(...)`.

## Testing

**Unit (dBriefWire / pure functions — no framework, CI-safe):**
- Prompt refactor: `systemPromptForGuidedGeneration` omits the JSON-format block and
  preserves the shared rules; `systemPrompt` still contains the JSON block.
- FoundationModels truncation budget (head/tail sizes, separator, threshold).
- `Sentiment` → `LocalInsightsResult` string normalization.
- Availability-reason → message mapping.

**Integration (manual, macOS 26 Apple Silicon — cannot run in CI):**
- Run a real recording through Apple Intelligence; confirm summary, action items,
  tags, sentiment, and title all populate, and tags are no longer occasionally empty.

## Out of scope

- Apple Speech modernization (separate PR).
- Remote-endpoint and Local-CLI engines.
- UI changes beyond progress-step labels (3 Apple Intelligence steps → 1).

## Files affected

- `Sources/dBrief/Services/LocalAIService.swift` — rewrite to guided generation + single method.
- `Sources/dBriefWire/UnifiedInsightsPrompt.swift` — split rules / JSON-format block; add guided variant.
- `Sources/dBrief/Services/RecordingManager.swift` — new unified Apple Intelligence task fn; remove old per-task + title calls; update step labels.
- `Sources/dBrief/Services/TranscriptChatService.swift` — prewarm + GenerationOptions for Apple Intelligence.
- `Tests/dBriefTests/` — new tests for prompt refactor, truncation, sentiment mapping, availability mapping.
- `CLAUDE.md` + `site/docs/` — update Apple Intelligence description (guided generation, unified call).
