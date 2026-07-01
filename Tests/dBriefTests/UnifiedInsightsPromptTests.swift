import Testing
@testable import dBrief
import dBriefWire

/// The unified-JSON insights contract is shared by the Gemma (MLX) and Local CLI
/// engines. These tests lock the schema/markers both engines depend on and confirm
/// CLI-style output parses through the same `decodeAndNormalize` path.
struct UnifiedInsightsPromptTests {

    @Test("System prompt declares the strict JSON schema fields")
    func systemPromptDeclaresSchema() {
        let prompt = UnifiedInsightsPrompt.systemPrompt(outputLanguage: .matchInput)
        #expect(prompt.contains("\"title_concept\""))
        #expect(prompt.contains("\"summary\""))
        #expect(prompt.contains("\"action_items\""))
        #expect(prompt.contains("\"tags\""))
        #expect(prompt.contains("\"sentiment\""))
    }

    @Test("Output-language instruction varies by selection")
    func languageInstructionVaries() {
        #expect(UnifiedInsightsPrompt.systemPrompt(outputLanguage: .english).contains("ENGLISH"))
        #expect(UnifiedInsightsPrompt.systemPrompt(outputLanguage: .dutch).contains("DUTCH"))
        #expect(UnifiedInsightsPrompt.systemPrompt(outputLanguage: .custom("fr")).contains("ISO Code FR"))
        #expect(UnifiedInsightsPrompt.systemPrompt(outputLanguage: .matchInput).contains("Match the language"))
    }

    @Test("User prompt embeds the transcript")
    func userPromptEmbedsTranscript() {
        let prompt = UnifiedInsightsPrompt.userPrompt(transcript: "Alice met Bob about Q3.")
        #expect(prompt.contains("Alice met Bob about Q3."))
        #expect(prompt.contains("TRANSCRIPT:"))
    }

    @Test("Short transcripts are not truncated")
    func shortTranscriptUntouched() {
        let text = "A brief transcript."
        #expect(UnifiedInsightsPrompt.truncate(text) == text)
    }

    @Test("Long transcripts keep head and tail with separator")
    func longTranscriptTruncated() {
        let text = String(repeating: "x", count: UnifiedInsightsPrompt.transcriptCharLimit + 1_000)
        let result = UnifiedInsightsPrompt.truncate(text)
        #expect(result.count < text.count)
        #expect(result.contains(UnifiedInsightsPrompt.truncationSeparator))
    }

    @Test("CLI-style JSON output parses through the shared decoder")
    func cliJSONParses() throws {
        let json = """
        {
          "title_concept": "Budget Planning Sync",
          "summary": "The team reviewed the Q3 budget and agreed on cuts.",
          "action_items": ["Alice to finalize the budget by Friday", "  "],
          "tags": ["budget", "planning", "Q3"],
          "sentiment": "Positive"
        }
        """
        let result = try LocalInsightsDecoder.decodeAndNormalize(json)
        #expect(result.titleConcept == "Budget Planning Sync")
        #expect(result.summary.contains("Q3 budget"))
        #expect(result.actionItems == ["Alice to finalize the budget by Friday"])
        #expect(result.tags.contains("budget"))
        #expect(result.sentiment.lowercased() == "positive")
    }

    @Test("CLI output wrapped in a <think> block still parses")
    func cliJSONWithThinkBlockParses() throws {
        let raw = """
        <think>Let me analyze this transcript carefully.</think>
        {
          "title_concept": "Standup",
          "summary": "Daily standup.",
          "action_items": [],
          "tags": ["standup"],
          "sentiment": "Neutral"
        }
        """
        let result = try LocalInsightsDecoder.decodeAndNormalize(raw)
        #expect(result.titleConcept == "Standup")
        #expect(result.actionItems.isEmpty)
    }

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

    // MARK: - Custom vocabulary

    @Test("vocabularyBlock is empty without configured vocabulary")
    func vocabularyBlockEmpty() {
        #expect(UnifiedInsightsPrompt.vocabularyBlock("") == "")
        #expect(UnifiedInsightsPrompt.vocabularyBlock("   \n ") == "")
    }

    @Test("vocabularyBlock embeds the configured terms")
    func vocabularyBlockEmbedsTerms() {
        let block = UnifiedInsightsPrompt.vocabularyBlock("Acme, Kubernetes")
        #expect(block.contains("DOMAIN-SPECIFIC TERMS"))
        #expect(block.contains("Acme, Kubernetes"))
    }

    @Test("System prompts embed vocabulary when provided, omit it when empty")
    func systemPromptsVocabulary() {
        let guided = UnifiedInsightsPrompt.systemPromptForGuidedGeneration(outputLanguage: .english, customVocabulary: "GraphQL")
        #expect(guided.contains("GraphQL"))
        let full = UnifiedInsightsPrompt.systemPrompt(outputLanguage: .english, customVocabulary: "GraphQL")
        #expect(full.contains("GraphQL"))

        let guidedEmpty = UnifiedInsightsPrompt.systemPromptForGuidedGeneration(outputLanguage: .english)
        #expect(!guidedEmpty.contains("DOMAIN-SPECIFIC TERMS"))
    }

    // MARK: - Per-field guidance (custom Summary / Action Items / Tags prompts)

    @Test("Without guidance the built-in SUMMARY rule is used")
    func defaultSummaryRuleWhenNoGuidance() {
        let prompt = UnifiedInsightsPrompt.systemPrompt(outputLanguage: .english)
        #expect(prompt.contains("thorough, multi-paragraph summary"))
    }

    @Test("Provided guidance replaces the built-in rules")
    func guidanceReplacesRules() {
        let prompt = UnifiedInsightsPrompt.systemPrompt(
            outputLanguage: .english,
            summaryGuidance: "Use 3-5 short bullet points.",
            actionItemsGuidance: "List owners in CAPS.",
            tagsGuidance: "Only product names."
        )
        #expect(prompt.contains("Use 3-5 short bullet points."))
        #expect(prompt.contains("List owners in CAPS."))
        #expect(prompt.contains("Only product names."))
        // The replaced built-in summary wording is gone.
        #expect(!prompt.contains("thorough, multi-paragraph summary"))
    }

    @Test("Empty/whitespace guidance falls back to the built-in rule")
    func blankGuidanceFallsBack() {
        let prompt = UnifiedInsightsPrompt.systemPrompt(
            outputLanguage: .english,
            summaryGuidance: "   \n  "
        )
        #expect(prompt.contains("thorough, multi-paragraph summary"))
    }

    @Test("The JSON envelope stays authoritative even with guidance")
    func envelopeRemainsAuthoritative() {
        // Mimics a real default tags prompt that says "output JSON only" — the envelope
        // preamble must still assert the single-object contract so it can't hijack output.
        let prompt = UnifiedInsightsPrompt.systemPrompt(
            outputLanguage: .english,
            summaryGuidance: "Output ONLY the summary, no JSON.",
            tagsGuidance: "Output a JSON object with exactly two fields."
        )
        #expect(prompt.contains("ENTIRE response MUST be a single JSON object"))
        #expect(prompt.contains("\"title_concept\""))
        #expect(prompt.contains("\"action_items\""))
    }

    @Test("Guidance bundle convenience matches the explicit params")
    func guidanceBundleMatchesParams() {
        let bundle = InsightsGuidance(summary: "Bullets.", actionItems: "Owners.", tags: "Topics.")
        let viaBundle = UnifiedInsightsPrompt.systemPrompt(outputLanguage: .english, guidance: bundle)
        let viaParams = UnifiedInsightsPrompt.systemPrompt(
            outputLanguage: .english,
            summaryGuidance: "Bullets.",
            actionItemsGuidance: "Owners.",
            tagsGuidance: "Topics."
        )
        #expect(viaBundle == viaParams)
    }

    @Test("Guided-generation prompt also honors summary guidance")
    func guidedPromptHonorsGuidance() {
        let guided = UnifiedInsightsPrompt.systemPromptForGuidedGeneration(
            outputLanguage: .english,
            summaryGuidance: "Use 3-5 short bullet points."
        )
        #expect(guided.contains("Use 3-5 short bullet points."))
        // Still no JSON block in the guided variant.
        #expect(!guided.contains("OUTPUT FORMAT"))
    }
}
