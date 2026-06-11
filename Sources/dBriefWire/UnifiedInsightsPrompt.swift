import Foundation

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

    /// Shared analysis rules + output-language instruction, WITHOUT any output-format
    /// section. Used directly by the FoundationModels guided-generation path (where the
    /// `@Generable` schema defines the shape) and composed with the JSON block for the
    /// Gemma/Local-CLI text path.
    public static func systemPromptForGuidedGeneration(outputLanguage: OutputLanguage, customVocabulary: String = "") -> String {
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
        \(vocabularyBlock(customVocabulary))
        """
    }

    public static func systemPrompt(outputLanguage: OutputLanguage, customVocabulary: String = "") -> String {
        systemPromptForGuidedGeneration(outputLanguage: outputLanguage, customVocabulary: customVocabulary) + """


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
}
