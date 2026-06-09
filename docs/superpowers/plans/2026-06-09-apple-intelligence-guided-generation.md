# Apple Intelligence Guided-Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert dBrief's Apple Intelligence insights path to a single macOS 26 guided-generation (`@Generable`) call that returns the shared `LocalInsightsResult`, matching the Gemma/Local-CLI unified contract, plus GenerationOptions tuning, prewarm, and richer availability messaging.

**Architecture:** `LocalAIService` is rewritten from 4 free-form `LanguageModelSession` calls into one `analyzeTranscript(_:outputLanguage:)` that uses constrained decoding against a private `@Generable MeetingInsights` struct, then maps to `LocalInsightsResult`. `RecordingManager` gets a `runAppleIntelligenceUnifiedTasks` that mirrors the existing `runLocalQwenTasks` (one call → summary + action items + tags + sentiment + inline title). The shared prompt in `dBriefWire` is split so a JSON-format-free variant feeds guided generation. The transcript chat path gains prewarm + GenerationOptions.

**Tech Stack:** Swift 6.2, SwiftPM, `FoundationModels` (macOS 26), swift-testing.

**Verified API facts (from the macOS SDK `FoundationModels.swiftinterface`):**
- `@Generable(description: String? = nil)` and `@Guide(description: String)` macros; `@Generable` works on structs and enums.
- `LanguageModelSession(instructions: String?)` convenience init; `LanguageModelSession()` (all defaults) is valid.
- `func respond<Content>(to: String, generating: Content.Type = Content.self, includeSchemaInPrompt: Bool = true, options: GenerationOptions = GenerationOptions()) async throws -> Response<Content> where Content: Generable` — access the value via `response.content`.
- `GenerationOptions(sampling: SamplingMode? = nil, temperature: Double? = nil, maximumResponseTokens: Int? = nil)`.
- `func prewarm(promptPrefix: Prompt? = nil)`.
- `SystemLanguageModel.default.availability: Availability` where `Availability = .available | .unavailable(UnavailableReason)`; `UnavailableReason = .deviceNotEligible | .appleIntelligenceNotEnabled | .modelNotReady` (not `@frozen` → use `@unknown default`).
- `LanguageModelSession.GenerationError` (a `LocalizedError`) cases include `.exceededContextWindowSize`, `.guardrailViolation`, `.unsupportedLanguageOrLocale`, `.decodingFailure`.

**Reconciliation with the spec:** The spec said "collapse 3 progress steps to 1." During planning we confirmed the Gemma path (`runLocalQwenTasks`) keeps all three step indices and marks them complete from its single call. To stay truly consistent with Gemma (the stated goal) and avoid UI churn, Apple Intelligence does the same: **three step entries are retained and completed together by one call. No step-label changes are needed.** This supersedes the spec's "collapse to 1" wording.

---

## File Structure

- **`Sources/dBriefWire/UnifiedInsightsPrompt.swift`** (modify) — split the system prompt into shared rules + JSON-format block; add `systemPromptForGuidedGeneration(outputLanguage:)` and `truncateForFoundationModels(_:)`. Pure, dependency-free, fully unit-testable.
- **`Sources/dBrief/Services/LocalAIService.swift`** (rewrite) — `@Generable` schema, single `analyzeTranscript`, availability/error mapping, `prewarm`, GenerationOptions. Drops `generateSummary`/`extractActionItems`/`analyzeTags`/`generateTitle`.
- **`Sources/dBrief/Services/RecordingManager.swift`** (modify) — replace `runAppleIntelligenceTasks` with `runAppleIntelligenceUnifiedTasks`; update the two dispatch call sites; exclude `.appleIntelligence` from the two separate title-generation blocks (which forces removal of the now-deleted `generateTitle` calls).
- **`Sources/dBrief/Services/TranscriptChatService.swift`** (modify) — add `prewarm()`; add GenerationOptions to the Apple Intelligence stream branch.
- **`Sources/dBrief/UI/TranscriptWindowView.swift`** (modify) — call `service.prewarm()` in `buildChatService()`.
- **`Tests/dBriefTests/UnifiedInsightsPromptTests.swift`** (extend) — guided-prompt + truncation tests.
- **`Tests/dBriefTests/LocalAIServiceMappingTests.swift`** (create) — sentiment-canonicalization + availability-message mapping (gated `@available(macOS 26)` / `#if canImport(FoundationModels)`).
- **`CLAUDE.md`** + **`site/docs/`** (modify) — document the guided-generation unified call.

---

## Task 1: Split the shared prompt + add FoundationModels helpers (dBriefWire)

**Files:**
- Modify: `Sources/dBriefWire/UnifiedInsightsPrompt.swift`
- Test: `Tests/dBriefTests/UnifiedInsightsPromptTests.swift`

- [ ] **Step 1: Write the failing tests**

Append these tests to `Tests/dBriefTests/UnifiedInsightsPromptTests.swift` (before the final closing `}`):

```swift
    @Test("Guided-generation prompt keeps the shared rules but omits the JSON schema block")
    func guidedPromptOmitsJSONBlock() {
        let guided = UnifiedInsightsPrompt.systemPromptForGuidedGeneration(outputLanguage: .matchInput)
        // Shared rules are present
        #expect(guided.contains("NO REPETITION"))
        #expect(guided.contains("ACTION ITEMS"))
        // The strict-JSON output section must NOT be present (the @Generable schema replaces it)
        #expect(!guided.contains("OUTPUT FORMAT"))
        #expect(!guided.contains("\"title_concept\""))
        #expect(!guided.contains("Strict JSON"))
    }

    @Test("Guided-generation prompt still varies output language")
    func guidedPromptLanguageVaries() {
        #expect(UnifiedInsightsPrompt.systemPromptForGuidedGeneration(outputLanguage: .english).contains("ENGLISH"))
        #expect(UnifiedInsightsPrompt.systemPromptForGuidedGeneration(outputLanguage: .dutch).contains("DUTCH"))
    }

    @Test("FoundationModels truncation leaves short transcripts untouched")
    func fmShortTranscriptUntouched() {
        let text = "A brief transcript."
        #expect(UnifiedInsightsPrompt.truncateForFoundationModels(text) == text)
    }

    @Test("FoundationModels truncation keeps head and tail within the small budget")
    func fmLongTranscriptTruncated() {
        let text = String(repeating: "x", count: UnifiedInsightsPrompt.foundationModelsCharLimit + 5_000)
        let result = UnifiedInsightsPrompt.truncateForFoundationModels(text)
        #expect(result.count < text.count)
        #expect(result.contains(UnifiedInsightsPrompt.truncationSeparator))
        // Far smaller than the Gemma 100K-char budget — must fit the ~4K-token window.
        #expect(result.count <= UnifiedInsightsPrompt.foundationModelsHeadChars
            + UnifiedInsightsPrompt.foundationModelsTailChars
            + UnifiedInsightsPrompt.truncationSeparator.count)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter UnifiedInsightsPromptTests`
Expected: FAIL — `systemPromptForGuidedGeneration` / `truncateForFoundationModels` / `foundationModelsCharLimit` are undefined.

- [ ] **Step 3: Refactor `UnifiedInsightsPrompt` to add the helpers**

In `Sources/dBriefWire/UnifiedInsightsPrompt.swift`, add the FoundationModels truncation budget near the existing constants (after line 16, the `truncationSeparator`):

```swift
    // Apple Intelligence (FoundationModels) has a ~4096-token context window — far
    // smaller than Gemma's 128K. It needs its own tight budget; the 100K-char
    // `truncate` above would overflow the window.
    public static let foundationModelsCharLimit = 12_000
    public static let foundationModelsHeadChars = 6_000
    public static let foundationModelsTailChars = 6_000

    public static func truncateForFoundationModels(_ transcript: String) -> String {
        guard transcript.count > foundationModelsCharLimit else { return transcript }
        let head = String(transcript.prefix(foundationModelsHeadChars))
        let tail = String(transcript.suffix(foundationModelsTailChars))
        return head + truncationSeparator + tail
    }
```

Then refactor `systemPrompt(outputLanguage:)` so the rules and JSON block are separable. Replace the entire existing `systemPrompt(outputLanguage:)` function (lines 37–75) with:

```swift
    /// Shared analysis rules + output-language instruction, WITHOUT any output-format
    /// section. Used directly by the FoundationModels guided-generation path (where the
    /// `@Generable` schema defines the shape) and composed with the JSON block for the
    /// Gemma/Local-CLI text path.
    public static func systemPromptForGuidedGeneration(outputLanguage: OutputLanguage) -> String {
        let languageInstruction: String = {
            switch outputLanguage {
            case .english:
                return "OUTPUT LANGUAGE: ENGLISH (Must translate if transcript is different)."
            case .dutch:
                return "OUTPUT LANGUAGE: DUTCH (Must translate if transcript is different)."
            case .custom(let code):
                return "OUTPUT LANGUAGE: ISO Code \(code.uppercased())."
            case .matchInput:
                return "OUTPUT LANGUAGE: Match the language of the transcript exactly."
            }
        }()

        return """
        You are an expert Senior Executive Assistant. Your goal is to extract structured meeting data from a transcript.

        \(languageInstruction)

        ### RULES
        1. **NO REPETITION:** If a point is made twice, record it once.
        2. **DETAIL:** Do not be vague. Use specific names, project names, tools, and deadlines mentioned in the transcript.
        3. **SUMMARY:** Write a thorough, multi-paragraph summary covering ALL major discussion topics.
        4. **ACTION ITEMS:** Extract ALL action items, even minor ones. Format: "[WHO] to [TASK] [CONTEXT/DEADLINE]".
        5. **TITLE CONCEPT:** Generate a short, 3-6 word descriptive title concept.
        6. **TAGS:** Provide 5-10 single words capturing the key topics discussed.
        7. **SENTIMENT:** One of "Positive", "Neutral", or "Negative" based on the overall tone.
        8. **TRUNCATION:** If you see "[...MIDDLE TEXT OMITTED FOR BREVITY...]", understand that the middle of the transcript was removed due to length constraints. Focus your summary on the available text.
        """
    }

    public static func systemPrompt(outputLanguage: OutputLanguage) -> String {
        systemPromptForGuidedGeneration(outputLanguage: outputLanguage) + """


        ### OUTPUT FORMAT (Strict JSON Only)
        {
          "title_concept": "Short Descriptive Title",
          "summary": "A detailed, multi-paragraph summary covering all key topics discussed...",
          "action_items": ["[Person] to [task] [context]", "..."],
          "tags": ["Tag1", "Tag2", "Tag3", "..."],
          "sentiment": "Positive" | "Neutral" | "Negative"
        }
        """
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter UnifiedInsightsPromptTests`
Expected: PASS (all tests, including the pre-existing `systemPromptDeclaresSchema` and `languageInstructionVaries`, which still see the JSON block + language text via the composed `systemPrompt`).

- [ ] **Step 5: Commit**

```bash
git add Sources/dBriefWire/UnifiedInsightsPrompt.swift Tests/dBriefTests/UnifiedInsightsPromptTests.swift
git commit -m "feat: split unified insights prompt for guided generation + FM truncation budget"
```

---

## Task 2: Rewrite `LocalAIService` to guided generation

**Files:**
- Rewrite: `Sources/dBrief/Services/LocalAIService.swift`
- Test: `Tests/dBriefTests/LocalAIServiceMappingTests.swift` (create)

- [ ] **Step 1: Write the failing mapping tests**

Create `Tests/dBriefTests/LocalAIServiceMappingTests.swift`:

```swift
import Testing
@testable import dBrief

#if canImport(FoundationModels)
import FoundationModels

/// Pure mapping tests for the Apple Intelligence backend. These exercise the
/// sentiment-canonicalization and availability-message helpers WITHOUT invoking the
/// on-device model (which needs entitlement + hardware). Gated to macOS 26 because
/// the helpers reference FoundationModels types.
@available(macOS 26, *)
struct LocalAIServiceMappingTests {

    @Test("Sentiment maps to the canonical capitalized strings")
    func sentimentCanonical() {
        #expect(LocalAIService.Sentiment.positive.canonical == "Positive")
        #expect(LocalAIService.Sentiment.neutral.canonical == "Neutral")
        #expect(LocalAIService.Sentiment.negative.canonical == "Negative")
    }

    @Test("Each unavailable reason produces a distinct, specific message")
    func availabilityMessages() {
        let eligible = LocalAIService.message(for: .deviceNotEligible)
        let notEnabled = LocalAIService.message(for: .appleIntelligenceNotEnabled)
        let notReady = LocalAIService.message(for: .modelNotReady)
        #expect(eligible != notEnabled)
        #expect(notEnabled != notReady)
        #expect(notEnabled.contains("System Settings"))
        #expect(notReady.lowercased().contains("download") || notReady.lowercased().contains("not ready"))
    }
}
#endif
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LocalAIServiceMappingTests`
Expected: FAIL — `LocalAIService.Sentiment` and `LocalAIService.message(for:)` don't exist yet.

- [ ] **Step 3: Rewrite `LocalAIService.swift`**

Replace the **entire** contents of `Sources/dBrief/Services/LocalAIService.swift` with:

```swift
#if canImport(FoundationModels)
import Foundation
import FoundationModels
import dBriefWire
import os

private let log = Logger.localAI

/// On-device AI using Apple Foundation Models (macOS 26+).
///
/// Uses guided generation (`@Generable`) to produce one structured `LocalInsightsResult`
/// in a single model call — matching the unified contract the Gemma (MLX) and Local CLI
/// engines use. Constrained decoding removes the hand-rolled JSON parsing and regex that
/// previously dropped tags / action items on malformed free-form output.
@available(macOS 26, *)
actor LocalAIService {

    // MARK: Guided-generation schema

    @Generable
    enum Sentiment {
        case positive
        case neutral
        case negative

        /// Canonical capitalized form expected by `LocalInsightsResult` and markdown.
        var canonical: String {
            switch self {
            case .positive: "Positive"
            case .neutral: "Neutral"
            case .negative: "Negative"
            }
        }
    }

    @Generable
    struct MeetingInsights {
        @Guide(description: "A thorough, multi-paragraph summary covering all major topics. Use specific names, project names, tools, and deadlines mentioned in the transcript.")
        var summary: String

        @Guide(description: "Every action item, even minor ones. Each formatted as '[WHO] to [TASK] [CONTEXT/DEADLINE]'.")
        var actionItems: [String]

        @Guide(description: "Five to ten single-word tags capturing the key topics discussed.")
        var tags: [String]

        var sentiment: Sentiment

        @Guide(description: "A short, 3-6 word descriptive title for the meeting.")
        var titleConcept: String
    }

    // MARK: Public API

    /// Runs one guided-generation pass and returns the unified insights result.
    /// Mirrors the Gemma/Local-CLI single-call contract (summary, action items, tags,
    /// sentiment, and an inline title concept).
    func analyzeTranscript(
        _ transcription: String,
        outputLanguage: OutputLanguage
    ) async throws -> LocalInsightsResult {
        try Self.ensureAvailable()

        let truncated = UnifiedInsightsPrompt.truncateForFoundationModels(transcription)
        let instructions = UnifiedInsightsPrompt.systemPromptForGuidedGeneration(outputLanguage: outputLanguage)
        let userPrompt = UnifiedInsightsPrompt.userPrompt(transcript: truncated)

        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 1_500)

        do {
            let response = try await session.respond(
                to: userPrompt,
                generating: MeetingInsights.self,
                options: options
            )
            let insights = response.content
            log.info("Apple Intelligence analysis complete: \(insights.summary.prefix(80), privacy: .public)...")
            return LocalInsightsResult(
                titleConcept: insights.titleConcept.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: insights.summary,
                actionItems: insights.actionItems,
                tags: insights.tags,
                sentiment: insights.sentiment.canonical
            )
        } catch let error as LanguageModelSession.GenerationError {
            throw LocalAIError.generation(Self.describe(error))
        }
    }

    /// Best-effort warm-up so the first real call has lower latency.
    func prewarm() {
        guard Self.isAvailable else { return }
        LanguageModelSession().prewarm()
    }

    // MARK: Availability

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Throws a specific, user-actionable error when the model can't run.
    static func ensureAvailable() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw LocalAIError.unavailable(message(for: reason))
        }
    }

    static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "Apple Intelligence is not supported on this Mac."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off. Enable it in System Settings → Apple Intelligence & Siri, then try again."
        case .modelNotReady:
            return "The Apple Intelligence model is still downloading or not ready yet. Try again shortly."
        @unknown default:
            return "Apple Intelligence is currently unavailable."
        }
    }

    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "The transcript is too long for Apple Intelligence. Try a shorter recording or a different AI engine."
        case .guardrailViolation:
            return "Apple Intelligence blocked this content with its safety guardrails."
        case .unsupportedLanguageOrLocale:
            return "Apple Intelligence does not support this language. Choose a different output language or AI engine."
        default:
            return error.localizedDescription
        }
    }
}

enum LocalAIError: Error, LocalizedError {
    case unavailable(String)
    case generation(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .generation(let message): message
        }
    }
}
#endif
```

- [ ] **Step 4: Run the mapping tests to verify they pass**

Run: `swift test --filter LocalAIServiceMappingTests`
Expected: PASS.

Note: the project will **not fully build yet** — `RecordingManager` still calls the removed `generateSummary`/`extractActionItems`/`analyzeTags`/`generateTitle`. That is fixed in Task 3. `swift test --filter` compiles the test target; if the whole-package compile blocks the filtered run, proceed to Task 3 and run the build there. Do **not** "fix" by re-adding the old methods.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/LocalAIService.swift Tests/dBriefTests/LocalAIServiceMappingTests.swift
git commit -m "feat: rewrite Apple Intelligence backend to guided generation"
```

---

## Task 3: Rewire `RecordingManager` to the unified Apple Intelligence call

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift` (function at 1017; dispatch at 301 and 512; title blocks at ~348 and ~552)

- [ ] **Step 1: Replace `runAppleIntelligenceTasks` with `runAppleIntelligenceUnifiedTasks`**

Replace the entire `runAppleIntelligenceTasks(...)` function (currently `Sources/dBrief/Services/RecordingManager.swift:1017-1084`) with:

```swift
    /// One guided-generation call producing summary, action items, tags, sentiment, and
    /// an inline title. Mirrors `runLocalQwenTasks`: the three step indices are all
    /// completed by the single call, so the progress UI stays consistent across engines.
    private func runAppleIntelligenceUnifiedTasks(
        transcription: String,
        localAvailable: Bool,
        summaryStepIndex: Int?,
        actionStepIndex: Int?,
        tagsStepIndex: Int?,
        recording: Recording
    ) async {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else {
            let message = "Apple Intelligence requires macOS 26+."
            markFailed(summaryStepIndex, message)
            markFailed(actionStepIndex, message)
            markFailed(tagsStepIndex, message)
            return
        }
        guard localAvailable else {
            let message = "Apple Intelligence is unavailable. Ensure it is enabled and your System + Siri languages match."
            markFailed(summaryStepIndex, message)
            markFailed(actionStepIndex, message)
            markFailed(tagsStepIndex, message)
            return
        }
        guard summaryStepIndex != nil || actionStepIndex != nil || tagsStepIndex != nil else { return }

        let contextualTranscription = CalendarEvent.augment(prompt: transcription, with: recording.calendarEvent)
        do {
            let insights = try await LocalAIService().analyzeTranscript(
                contextualTranscription,
                outputLanguage: appSettings.outputLanguage
            )

            if let summaryStepIndex {
                recording.summary = insights.summary
                markCompleted(summaryStepIndex)
            }
            let trimmedTitle = insights.titleConcept.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                let datePrefix = Self.dateOnlyString(recording.date)
                recording.generatedTitle = "\(datePrefix) - \(trimmedTitle)"
            }
            if let actionStepIndex {
                recording.actionItems = insights.actionItems
                markCompleted(actionStepIndex)
            }
            if let tagsStepIndex {
                recording.tags = insights.tags
                recording.sentiment = insights.sentiment
                markCompleted(tagsStepIndex)
            }
        } catch {
            let message = error.localizedDescription
            markFailed(summaryStepIndex, message)
            markFailed(actionStepIndex, message)
            markFailed(tagsStepIndex, message)
        }
        #else
        let message = "Apple Intelligence is unavailable in this build."
        markFailed(summaryStepIndex, message)
        markFailed(actionStepIndex, message)
        markFailed(tagsStepIndex, message)
        #endif
    }
```

- [ ] **Step 2: Update the two dispatch call sites**

At `Sources/dBrief/Services/RecordingManager.swift:301` and `:512`, rename the called function. Both currently read:

```swift
                await runAppleIntelligenceTasks(
```

Change both to:

```swift
                await runAppleIntelligenceUnifiedTasks(
```

(The argument list — `transcription:`, `localAvailable:`, the three step indices, `recording:` — is unchanged.)

- [ ] **Step 3: Exclude Apple Intelligence from the first separate title block**

In the first title-generation block (around `Sources/dBrief/Services/RecordingManager.swift:347-377`), the outer condition currently is:

```swift
            if engine != .qwenLocal, engine != .localCLI,
               let transcriptionText = recording.transcription?.textForLLM,
               !transcriptionText.isEmpty {
```

Change it to also exclude `.appleIntelligence`:

```swift
            if engine != .qwenLocal, engine != .localCLI, engine != .appleIntelligence,
               let transcriptionText = recording.transcription?.textForLLM,
               !transcriptionText.isEmpty {
```

Then, inside that block, replace the now-broken `#if canImport(FoundationModels)` … `#endif` `do` body (which still references the removed `LocalAIService().generateTitle`) with a FoundationModels-free version that only handles the remote endpoint:

```swift
                do {
                    if engine == .remoteEndpoint,
                       let endpoint = appSettings.effectiveDefaultAIEndpoint {
                        recording.generatedTitle = try await aiService.generateTitle(
                            transcription: titleInput,
                            language: language,
                            endpoint: endpoint
                        )
                    }
                    appState.processingSteps[titleStepIndex].status = .completed
                } catch {
                    // Title generation is non-critical — fall back to text extraction
                    appState.processingSteps[titleStepIndex].status = .completed
                }
```

- [ ] **Step 4: Exclude Apple Intelligence from the second separate title block**

In the second title-generation block (around `Sources/dBrief/Services/RecordingManager.swift:552-585`), the outer condition currently is:

```swift
        if engine != .qwenLocal,
           let transcriptionText = recording.transcription?.textForLLM,
           !transcriptionText.isEmpty {
```

Change it to:

```swift
        if engine != .qwenLocal, engine != .localCLI, engine != .appleIntelligence,
           let transcriptionText = recording.transcription?.textForLLM,
           !transcriptionText.isEmpty {
```

Then replace that block's `#if canImport(FoundationModels)` … `#endif` `do` body the same way as Step 3:

```swift
            do {
                if engine == .remoteEndpoint,
                   let endpoint = appSettings.effectiveDefaultAIEndpoint {
                    recording.generatedTitle = try await aiService.generateTitle(
                        transcription: titleInput,
                        language: language,
                        endpoint: endpoint
                    )
                }
                appState.processingSteps[titleStepIndex].status = .completed
            } catch {
```

> Note: keep whatever currently follows the `catch {` in that block (the existing fall-back line that sets the step `.completed`). Only the inner `if/else if` + the `#if/#else/#endif` wrapper are being replaced; the surrounding `do`/`catch` structure stays.

- [ ] **Step 5: Build the whole package**

Run: `swift build`
Expected: SUCCESS. (This is the first point everything compiles together — Task 2's removals are now resolved.)

- [ ] **Step 6: Run the full test suite**

Run: `swift test`
Expected: PASS — all existing tests plus the new Task 1 / Task 2 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift
git commit -m "feat: route Apple Intelligence through the unified guided-generation call"
```

---

## Task 4: Tune the transcript chat path

**Files:**
- Modify: `Sources/dBrief/Services/TranscriptChatService.swift` (Apple Intelligence branch at 86-103; add `prewarm()`)
- Modify: `Sources/dBrief/UI/TranscriptWindowView.swift` (`buildChatService()` at 427)

- [ ] **Step 1: Add GenerationOptions + prewarm to the Apple Intelligence stream branch**

In `Sources/dBrief/Services/TranscriptChatService.swift`, replace the `case .appleIntelligence:` branch body (lines 86-103) with:

```swift
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                return AsyncThrowingStream { continuation in
                    Task {
                        do {
                            let session = LanguageModelSession(instructions: systemPrompt)
                            session.prewarm()
                            let options = GenerationOptions(temperature: 0.5)
                            let response = try await session.respond(to: userMessage, options: options)
                            continuation.yield(response.content)
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }
            #endif
            return errorStream("Apple Intelligence requires macOS 26 or later")
```

- [ ] **Step 2: Add a `prewarm()` method to `TranscriptChatService`**

In `Sources/dBrief/Services/TranscriptChatService.swift`, add this method right after `clearMessages()` (after line 64):

```swift
    /// Warms the on-device model when the chat panel opens so the first answer streams
    /// sooner. No-op unless Apple Intelligence is the active (or fallback) chat engine.
    func prewarm() {
        let engine = appSettings.effectiveAIEngine == .localCLI
            ? appSettings.chatFallbackEngine
            : appSettings.effectiveAIEngine
        guard engine == .appleIntelligence else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            LanguageModelSession().prewarm()
        }
        #endif
    }
```

- [ ] **Step 3: Call `prewarm()` when the chat service is built**

In `Sources/dBrief/UI/TranscriptWindowView.swift`, in `buildChatService()` (starts line 427), the function creates a `TranscriptChatService(...)` as `service`, then stores it and assigns `chatService = service` (read lines 437-446 to confirm the exact assignment). Immediately after the line that assigns `chatService = service`, add:

```swift
        service.prewarm()
```

(If the existing tail assigns via `chatStore` and `chatService` separately, place `service.prewarm()` after both, before the function returns. The call is synchronous and `@MainActor`-safe.)

- [ ] **Step 4: Build**

Run: `swift build`
Expected: SUCCESS.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/TranscriptChatService.swift Sources/dBrief/UI/TranscriptWindowView.swift
git commit -m "feat: prewarm + tune Apple Intelligence chat generation"
```

---

## Task 5: Update documentation

**Files:**
- Modify: `CLAUDE.md` (AI Processing table — Apple Intelligence row)
- Modify: `site/docs/` (the AI-engines page; update NAV in `site/docs.js` only if a new page is added — none is)

- [ ] **Step 1: Update the Apple Intelligence description in `CLAUDE.md`**

In the **AI Processing** section table, change the Apple Intelligence (`LocalAIService`) backend cell from:

```
On-device via `FoundationModels` framework. Guarded by `#if canImport(FoundationModels)` and `@available(macOS 26, *)`. Only available on Apple Silicon with macOS 26+.
```

to:

```
On-device via `FoundationModels` framework. Guarded by `#if canImport(FoundationModels)` and `@available(macOS 26, *)`. Only available on Apple Silicon with macOS 26+. Uses **guided generation** (`@Generable`/`@Guide`) to produce one structured `LocalInsightsResult` in a single call (summary, action items, tags, sentiment, inline title) — like the Gemma/Local-CLI unified path, sharing `UnifiedInsightsPrompt.systemPromptForGuidedGeneration`. Tight ~12K-char transcript budget for the ~4K-token window; `GenerationOptions(temperature: 0.3)`; specific availability messaging via `SystemLanguageModel.availability`.
```

Also update the paragraph just below the table that begins "AI tasks run sequentially after transcription: summary → action items → ..." to note that **Apple Intelligence now joins the unified-JSON engines** (Gemma, Local CLI) that produce all fields — including `title_concept` — in one call and skip the separate title-generation step.

- [ ] **Step 2: Mirror the change in the public docs site**

Run: `grep -rn "Apple Intelligence" site/docs/` to find the AI-engines page. In the matching file, update the Apple Intelligence description to mention guided generation / single unified call, matching the CLAUDE.md wording. No new page is added, so `site/docs.js` NAV does not change. If no `site/docs/` reference to Apple Intelligence exists, skip this step and note it in the commit body.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md site/docs/
git commit -m "docs: document Apple Intelligence guided-generation unified call"
```

---

## Manual Verification (macOS 26, Apple Silicon — cannot run in CI)

After all tasks land, build and run the app, then process one real recording with the Apple Intelligence engine selected:

- [ ] Summary, action items, tags, sentiment, **and** title all populate.
- [ ] Run a transcript whose tags previously came back empty under the old JSON-parsing path; confirm tags are now populated.
- [ ] Sentiment renders as exactly `Positive` / `Neutral` / `Negative`.
- [ ] The processing UI shows the three AI steps all completing (no orphaned "Generating Title" step).
- [ ] Open the transcript chat with Apple Intelligence as the engine; the first answer streams and is coherent.
- [ ] Temporarily disable Apple Intelligence in System Settings and process again; confirm the specific "turned off … System Settings" message appears rather than the old generic one.

---

## Self-Review

**Spec coverage:**
- Guided-generation conversion → Task 2. ✓
- Unified single call matching Gemma contract → Task 2 (`analyzeTranscript` → `LocalInsightsResult`) + Task 3 (`runAppleIntelligenceUnifiedTasks`). ✓
- Shared prompt split (rules vs JSON block) → Task 1. ✓
- FoundationModels-specific truncation budget → Task 1. ✓
- GenerationOptions tuning → Task 2 (insights) + Task 4 (chat). ✓
- Prewarm → Task 2 (`prewarm()`) + Task 4 (chat view wiring). ✓
- Better availability messaging → Task 2 (`ensureAvailable` / `message(for:)`). ✓
- Error handling mapping → Task 2 (`describe`). ✓
- Chat-path tuning → Task 4. ✓
- Inline title (skip separate title step) → Task 3 Steps 3–4. ✓
- Tests (prompt, truncation, sentiment, availability) → Tasks 1 & 2. ✓
- Docs (CLAUDE.md + site/docs) → Task 5. ✓
- Out-of-scope items (Apple Speech, remote/CLI engines) → untouched. ✓

**Type consistency:** `analyzeTranscript(_:outputLanguage:)` returns `LocalInsightsResult` (existing shared type); `Sentiment.canonical: String`; `MeetingInsights` field names (`summary`, `actionItems`, `tags`, `sentiment`, `titleConcept`) map 1:1 to `LocalInsightsResult.init(titleConcept:summary:actionItems:tags:sentiment:)`. `runAppleIntelligenceUnifiedTasks` signature matches the two dispatch call sites. `message(for:)` and `Sentiment` are referenced by `LocalAIServiceMappingTests` with the same access.

**Placeholder scan:** No TBD/TODO. The only conditional instruction (Task 4 Step 3 / Task 5 Step 2) gives an exact anchor + fallback, not a vague "handle it."
