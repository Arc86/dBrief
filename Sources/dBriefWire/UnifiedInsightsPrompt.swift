import Foundation

/// The user's configured Summary / Action Items / Tags prompts, carried to the unified
/// engines so on-device/CLI analysis honors the same prompts as the Remote Endpoint.
/// Each field is optional; an empty/absent field falls back to the built-in rule.
public struct InsightsGuidance: Sendable, Codable, Equatable {
    public var summary: String?
    public var actionItems: String?
    public var tags: String?

    public init(summary: String? = nil, actionItems: String? = nil, tags: String? = nil) {
        self.summary = summary
        self.actionItems = actionItems
        self.tags = tags
    }
}

/// Shared prompt contract for the "unified JSON" insights path used by both the
/// local Gemma (MLX) engine (in the helper) and the Local CLI engine (in the app).
/// Both ask a model to return a single JSON object (`title_concept`, `summary`,
/// `action_items`, `tags`, `sentiment`) parsed by `LocalInsightsDecoder`. Lives in
/// `dBriefWire` so both targets share one schema and stay in lockstep.
public enum UnifiedInsightsPrompt {
    // Transcript budgeting. Gemma 4 E4B has a 128K context (~25K input tokens at
    // ~4 chars/token); agentic CLIs are typically large-context too. Keep a small
    // intro slice for context, then the full tail — meetings load substance in the
    // middle and end, so dropping the head preserves detail.
    public static let transcriptCharLimit = 100_000
    public static let transcriptHeadChars = 5_000
    public static let transcriptTailChars = 95_000
    public static let truncationSeparator = "\n\n[...MIDDLE TEXT OMITTED FOR BREVITY...]\n\n"

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

    public static func truncate(_ transcript: String) -> String {
        guard transcript.count > transcriptCharLimit else { return transcript }
        let head = String(transcript.prefix(transcriptHeadChars))
        let tail = String(transcript.suffix(transcriptTailChars))
        return head + truncationSeparator + tail
    }

    public static func userPrompt(transcript: String) -> String {
        """
        Analyze this transcript and produce the JSON response exactly as required by the system instructions.
        Do not copy template phrases. Use only factual details present in the transcript.

        TRANSCRIPT:
        \(transcript)

        INSTRUCTION: Focus on extracting specific names, projects, tools, and deadlines mentioned in the text. Ensure the summary is thorough and covers all discussion topics.
        """
    }

    /// A "spell these exactly" domain-terms block for the system prompt, or "" when no
    /// custom vocabulary is configured. Reuses the user's existing custom-vocabulary
    /// string (the same one that biases Whisper) so proper nouns are spelled correctly
    /// in AI output too. Also used by the remote per-task prompts.
    public static func vocabularyBlock(_ customVocabulary: String) -> String {
        let trimmed = customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """

        ### DOMAIN-SPECIFIC TERMS
        Spell the following proper nouns, acronyms, and product names exactly as written when they appear: \(trimmed)
        """
    }

    /// Trimmed guidance string or `nil` when empty — so callers can pass an
    /// `effective*Prompt` straight through and an unset value falls back to the
    /// built-in rule below.
    private static func guidance(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Shared analysis rules + output-language instruction, WITHOUT any output-format
    /// section. Used directly by the FoundationModels guided-generation path (where the
    /// `@Generable` schema defines the shape) and composed with the JSON block for the
    /// Gemma/Local-CLI text path.
    ///
    /// `summaryGuidance` / `actionItemsGuidance` / `tagsGuidance` carry the user's
    /// configured Summary / Action Items / Tags prompts. When non-empty they replace the
    /// corresponding built-in rule, so the unified engines honor the same prompts as the
    /// Remote Endpoint. The output container (the JSON envelope below, or the
    /// `@Generable` schema for FoundationModels) always stays authoritative — see
    /// `systemPrompt`.
    public static func systemPromptForGuidedGeneration(
        outputLanguage: OutputLanguage,
        customVocabulary: String = "",
        summaryGuidance: String? = nil,
        actionItemsGuidance: String? = nil,
        tagsGuidance: String? = nil
    ) -> String {
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

        let summaryRule = guidance(summaryGuidance)
            ?? "Write a thorough, multi-paragraph summary covering ALL major discussion topics."
        let actionItemsRule = guidance(actionItemsGuidance)
            ?? "Extract ALL action items, even minor ones. Format: \"[WHO] to [TASK] [CONTEXT/DEADLINE]\"."
        let tagsRule = guidance(tagsGuidance)
            ?? "Provide 5-10 single words capturing the key topics discussed, and choose a sentiment of \"Positive\", \"Neutral\", or \"Negative\" based on the overall tone."

        return """
        You are an expert Senior Executive Assistant. Your goal is to extract structured meeting data from a transcript.

        \(languageInstruction)

        ### RULES
        1. **NO REPETITION:** If a point is made twice, record it once.
        2. **DETAIL:** Do not be vague. Use specific names, project names, tools, and deadlines mentioned in the transcript.
        3. **SUMMARY:** \(summaryRule)
        4. **ACTION ITEMS:** \(actionItemsRule)
        5. **TITLE CONCEPT:** Generate a short, 3-6 word descriptive title concept.
        6. **TAGS & SENTIMENT:** \(tagsRule)
        7. **TRUNCATION:** If you see "[...MIDDLE TEXT OMITTED FOR BREVITY...]", understand that the middle of the transcript was removed due to length constraints. Focus your summary on the available text.
        \(vocabularyBlock(customVocabulary))
        """
    }

    /// Convenience: build the guided-generation prompt from an `InsightsGuidance` bundle.
    public static func systemPromptForGuidedGeneration(
        outputLanguage: OutputLanguage,
        customVocabulary: String = "",
        guidance: InsightsGuidance?
    ) -> String {
        systemPromptForGuidedGeneration(
            outputLanguage: outputLanguage,
            customVocabulary: customVocabulary,
            summaryGuidance: guidance?.summary,
            actionItemsGuidance: guidance?.actionItems,
            tagsGuidance: guidance?.tags
        )
    }

    /// Convenience: build the full JSON-contract prompt from an `InsightsGuidance` bundle.
    public static func systemPrompt(
        outputLanguage: OutputLanguage,
        customVocabulary: String = "",
        guidance: InsightsGuidance?
    ) -> String {
        systemPrompt(
            outputLanguage: outputLanguage,
            customVocabulary: customVocabulary,
            summaryGuidance: guidance?.summary,
            actionItemsGuidance: guidance?.actionItems,
            tagsGuidance: guidance?.tags
        )
    }

    public static func systemPrompt(
        outputLanguage: OutputLanguage,
        customVocabulary: String = "",
        summaryGuidance: String? = nil,
        actionItemsGuidance: String? = nil,
        tagsGuidance: String? = nil
    ) -> String {
        systemPromptForGuidedGeneration(
            outputLanguage: outputLanguage,
            customVocabulary: customVocabulary,
            summaryGuidance: summaryGuidance,
            actionItemsGuidance: actionItemsGuidance,
            tagsGuidance: tagsGuidance
        ) + """


        ### OUTPUT FORMAT (Strict JSON Only)
        Regardless of any formatting, headings, or "output only…" phrasing mentioned in the rules above,
        your ENTIRE response MUST be a single JSON object exactly as specified below — nothing before or after it.
        Place the full summary text, INCLUDING any bullet points, headings, or line breaks the rules call for,
        inside the "summary" string (use "\\n" for line breaks). Put each action item as its own string in the
        "action_items" array, and the topic tags in the "tags" array.
        {
          "title_concept": "Short Descriptive Title",
          "summary": "The summary text, formatted as the SUMMARY rule requires...",
          "action_items": ["[Person] to [task] [context]", "..."],
          "tags": ["Tag1", "Tag2", "Tag3", "..."],
          "sentiment": "Positive" | "Neutral" | "Negative"
        }
        """
    }
}
