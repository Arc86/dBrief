import Testing
import dBriefWire

@Suite struct CommitmentPolicyTests {
    let guidance = InsightsGuidance(summary: "S", actionItems: "ACTION-GUIDE", tags: "T")

    /// Golden copies of the map prompt before the commitment policy existed: the
    /// Gemma path (`.inclusive`, the default) must stay byte-identical.
    let goldenEnglish = #"""
        You are taking detailed notes on ONE PART of a long meeting transcript. A later step merges the notes from every part, so capture everything from THIS part and nothing else.

        OUTPUT LANGUAGE: ENGLISH (Must translate if transcript is different).

        ### RULES
        1. **action_items:** Every commitment, task or follow-up. Format each as "[WHO] to [TASK] [CONTEXT/DEADLINE]". Each MUST start with [WHO]; use [Unassigned] only if the owner is unknown. If this part contains no commitments, return an empty list — never write a placeholder such as 'No action items'.
        2. **decisions:** Every decision or agreement reached in this part. If this part contains no decisions, return an empty list — never write a placeholder such as 'No decisions'.
        3. **people:** Names of everyone who speaks or is mentioned in this part.
        4. **key_points:** Every distinct topic, fact, number, name, product, risk and concern discussed in this part, one specific sentence each. Do not compress details away.
        5. The part may begin or end mid-conversation. Record only what is actually said; never invent.


        Inside every JSON string value, never use the double-quote character; when you need to quote something, use single quotes ('like this').
        """#
    let goldenDutchGuided = #"""
        You are taking detailed notes on ONE PART of a long meeting transcript. A later step merges the notes from every part, so capture everything from THIS part and nothing else.

        OUTPUT LANGUAGE: DUTCH (Must translate if transcript is different).

        ### RULES
        1. **action_items:** Every commitment, task or follow-up. ACTION-GUIDE Each MUST start with [WHO]; use [Unassigned] only if the owner is unknown. If this part contains no commitments, return an empty list — never write a placeholder such as 'No action items'.
        2. **decisions:** Every decision or agreement reached in this part. If this part contains no decisions, return an empty list — never write a placeholder such as 'No decisions'.
        3. **people:** Names of everyone who speaks or is mentioned in this part.
        4. **key_points:** Every distinct topic, fact, number, name, product, risk and concern discussed in this part, one specific sentence each. Do not compress details away.
        5. The part may begin or end mid-conversation. Record only what is actually said; never invent.

        ### DOMAIN-SPECIFIC TERMS
        Spell the following proper nouns, acronyms, and product names exactly as written when they appear: dBrief

        Inside every JSON string value, never use the double-quote character; when you need to quote something, use single quotes ('like this').
        """#

    @Test func inclusivePolicyIsByteIdenticalToThePreviousPrompt() {
        #expect(UnifiedInsightsPrompt.chunkNotesSystemPrompt(outputLanguage: .english, customVocabulary: "", guidance: nil)
                == goldenEnglish)
        #expect(UnifiedInsightsPrompt.chunkNotesSystemPrompt(outputLanguage: .english, customVocabulary: "", guidance: nil,
                                                             commitments: .inclusive) == goldenEnglish)
        #expect(UnifiedInsightsPrompt.chunkNotesSystemPrompt(outputLanguage: .dutch, customVocabulary: "dBrief", guidance: guidance,
                                                             commitments: .inclusive) == goldenDutchGuided)
    }

    @Test func explicitOnlyPolicyAsksForExplicitCommitmentsOnly() {
        let p = UnifiedInsightsPrompt.chunkNotesSystemPrompt(outputLanguage: .dutch, customVocabulary: "dBrief", guidance: guidance,
                                                             commitments: .explicitOnly)
        #expect(p.contains("Only explicit commitments: someone says they, or a named person, WILL do something."))
        #expect(p.contains("Not topics, suggestions, questions, or work already done."))
        #expect(p.contains("Most parts have none, or one or two."))
        #expect(p.contains("If there are none, return an empty list — never write a placeholder."))
        #expect(!p.contains("Every commitment, task or follow-up"))
        // Everything else is shared with the inclusive prompt.
        #expect(p.contains("ACTION-GUIDE") && p.contains("[WHO]") && p.contains("DUTCH") && p.contains("dBrief"))
        #expect(p.contains("**decisions:**") && p.contains("never use the double-quote character"))
    }
}
