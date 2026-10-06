#if canImport(FoundationModels)
import Foundation
import FoundationModels
import dBriefWire
import os

private let log = Logger.localAI

/// On-device AI using Apple Foundation Models (macOS 26+).
///
/// Uses guided generation (`@Generable`) to produce one structured `LocalInsightsResult`
/// — in a single model call when the transcript fits the context window, else by a
/// lossless map-reduce — matching the unified contract the Gemma (MLX) and Local CLI
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

    // The @Guide descriptions are intentionally style-neutral: the concrete
    // formatting (bullets vs. prose, structure, owners, etc.) is driven by the
    // user's Summary / Action Items / Tags prompts injected into `instructions`
    // (see `analyzeTranscript`). A prescriptive @Guide here would fight that.
    @Generable
    struct MeetingInsights {
        @Guide(description: "The meeting summary, written and formatted exactly as the SUMMARY rule in the instructions requires.")
        var summary: String

        @Guide(description: "The action items, each as its own string, following the ACTION ITEMS rule in the instructions.")
        var actionItems: [String]

        @Guide(description: "The topic tags, following the TAGS rule in the instructions.")
        var tags: [String]

        var sentiment: Sentiment

        @Guide(description: "A short, 3-6 word descriptive title for the meeting.")
        var titleConcept: String
    }

    /// Notes for one transcript part (map step) or a merged group of parts (condense).
    /// Declared actions-first: generation follows declaration order, so the high-value
    /// lists are produced before the open-ended key-points list can run long.
    @Generable
    struct PartNotes {
        @Guide(description: "Every commitment or task, following the action_items rule in the instructions. One short line each, in your own words; never copy transcript text.", .maximumCount(10))
        var actionItems: [String]

        @Guide(description: "Every decision or agreement reached in this part, one short sentence each, in your own words.", .maximumCount(8))
        var decisions: [String]

        @Guide(description: "Only the names of everyone who speaks or is mentioned in this part.", .maximumCount(12))
        var people: [String]

        @Guide(description: "Every distinct topic, fact, number, name and concern in this part, one short specific sentence each (at most 25 words), in your own words; never copy transcript lines.", .maximumCount(10))
        var keyPoints: [String]

        var chunkNotes: ChunkNotes {
            ChunkNotes(keyPoints: keyPoints, decisions: decisions, actionItems: actionItems, people: people).deduplicated()
        }
    }

    /// The final record for the map-reduce path; action items come from the map notes.
    @Generable
    struct MeetingRecord {
        @Guide(description: "The meeting summary, written and formatted exactly as the SUMMARY rule in the instructions requires.")
        var summary: String

        @Guide(description: "The topic tags, following the TAGS rule in the instructions.")
        var tags: [String]

        var sentiment: Sentiment

        @Guide(description: "A short, 3-6 word descriptive title for the meeting.")
        var titleConcept: String
    }

    // MARK: Public API

    /// Unified insights (summary, action items, tags, sentiment, inline title concept),
    /// mirroring the Gemma/Local-CLI contract. A transcript that fits the model's window
    /// gets one guided pass; a longer one is analyzed losslessly by map-reduce (notes
    /// per part, then a final record), sized to `SystemLanguageModel.default.contextSize`.
    /// `context` (calendar roster/agenda) is kept out of the chunked text and prefixed to
    /// every prompt.
    func analyzeTranscript(
        _ transcript: String,
        context: String = "",
        outputLanguage: OutputLanguage,
        customVocabulary: String = "",
        summaryGuidance: String? = nil,
        actionItemsGuidance: String? = nil,
        tagsGuidance: String? = nil
    ) async throws -> LocalInsightsResult {
        try Self.ensureAvailable()
        let budget = AppleAnalysisBudget.from(contextSize: SystemLanguageModel.default.contextSize)
        let full = context.isEmpty ? transcript : context + "\n\n" + transcript
        let guidance = InsightsGuidance(summary: summaryGuidance, actionItems: actionItemsGuidance, tags: tagsGuidance)
        do {
            if await Self.tokens(full) <= budget.singlePassTranscriptTokens {
                return try await singlePass(full, outputLanguage: outputLanguage, customVocabulary: customVocabulary,
                                            guidance: guidance, maxResponse: budget.finalResponseTokens)
            }
            return try await mapReduce(transcript, context: context, budget: budget, outputLanguage: outputLanguage,
                                       customVocabulary: customVocabulary, guidance: guidance)
        } catch let error as LanguageModelSession.GenerationError {
            throw LocalAIError.generation(Self.describe(error))
        }
    }

    /// Exact on macOS 26.4+, conservative estimate before.
    private static func tokens(_ text: String) async -> Int {
        if #available(macOS 26.4, *), let exact = try? await SystemLanguageModel.default.tokenCount(for: text) {
            return exact
        }
        return AppleAnalysisBudget.estimateTokens(text)
    }

    private func singlePass(_ transcript: String, outputLanguage: OutputLanguage, customVocabulary: String,
                            guidance: InsightsGuidance, maxResponse: Int) async throws -> LocalInsightsResult {
        let instructions = UnifiedInsightsPrompt.systemPromptForGuidedGeneration(
            outputLanguage: outputLanguage, customVocabulary: customVocabulary, guidance: guidance)
        let insights = try await respond(
            instructions: instructions, prompt: UnifiedInsightsPrompt.userPrompt(transcript: transcript),
            generating: MeetingInsights.self, maxResponse: maxResponse)
        log.info("Apple Intelligence analysis complete: summaryLength=\(insights.summary.count) actions=\(insights.actionItems.count) tags=\(insights.tags.count)")
        return LocalInsightsResult(
            titleConcept: insights.titleConcept,
            summary: insights.summary,
            actionItems: insights.actionItems,
            tags: insights.tags,
            sentiment: insights.sentiment.canonical
        )
    }

    // MARK: Long-transcript map-reduce

    private func mapReduce(_ transcript: String, context: String, budget: AppleAnalysisBudget,
                           outputLanguage: OutputLanguage, customVocabulary: String,
                           guidance: InsightsGuidance) async throws -> LocalInsightsResult {
        let contextTokens = AppleAnalysisBudget.estimateTokens(context)
        let parts = TranscriptChunkPlanner.plan(transcript, maxTokensPerChunk: max(400, budget.chunkTokens - contextTokens),
                                                overlapLines: 1, countTokens: AppleAnalysisBudget.estimateTokens)
        log.info("Apple Intelligence map-reduce: \(parts.count) parts")
        let mapSystem = UnifiedInsightsPrompt.chunkNotesSystemPrompt(
            outputLanguage: outputLanguage, customVocabulary: customVocabulary, guidance: guidance)

        var notes: [ChunkNotes] = []
        for part in parts {
            try Task.checkCancellation()
            MLProgress.sink?(.analyzingPart(index: part.index, total: part.total))
            notes.append(try await notesForPart(part, system: mapSystem, context: context, budget: budget))
        }

        // Hierarchical reduce: condense consecutive notes until they fit one reduce prompt.
        try Task.checkCancellation()
        MLProgress.sink?(.analyzingPart(index: parts.count + 1, total: parts.count))
        var level = NotesReducePlanner.withoutActions(notes)
        while true {
            let groups = NotesReducePlanner.groups(level, budget: budget.reduceInputTokens,
                                                   countTokens: AppleAnalysisBudget.estimateTokens)
            guard groups.count > 1, groups.count < level.count else { break } // fits, or no further merging possible
            Self.diagnostic("condensing \(level.count) notes into \(groups.count)")
            var condensed: [ChunkNotes] = []
            for group in groups {
                try Task.checkCancellation()
                condensed.append(group.count == 1
                                 ? group[0]
                                 : try await condense(group, outputLanguage: outputLanguage, budget: budget))
            }
            level = condensed
        }
        let notesText = ChunkNotesMerger.reduceInput(level, maxTokens: max(400, budget.reduceInputTokens - contextTokens),
                                                     countTokens: AppleAnalysisBudget.estimateTokens)
        try Task.checkCancellation()
        let record: MeetingRecord
        do {
            record = try await respond(
                instructions: UnifiedInsightsPrompt.reduceSystemPrompt(outputLanguage: outputLanguage, customVocabulary: customVocabulary,
                                                                       guidance: guidance, forGuidedGeneration: true),
                prompt: UnifiedInsightsPrompt.reduceUserPrompt(context: context, notes: notesText),
                generating: MeetingRecord.self, maxResponse: budget.finalResponseTokens)
        } catch let error as LanguageModelSession.GenerationError {
            Self.diagnostic("final record failed: \(Self.caseName(error))")
            throw error
        }
        let actionItems = ChunkNotesMerger.mergedActionItems(notes)
        log.info("Apple Intelligence map-reduce complete: parts=\(parts.count) summaryLength=\(record.summary.count) actions=\(actionItems.count)")
        return LocalInsightsResult(titleConcept: record.titleConcept, summary: record.summary,
                                   actionItems: actionItems,
                                   tags: record.tags, sentiment: record.sentiment.canonical)
    }

    /// Notes for one part. When the part fails (overflows the window, its notes run past
    /// the response cap and fail to decode, or it is refused even as text), it is split
    /// once into halves and each half is mapped, so no part is ever skipped. A half that
    /// still fails, or a part too small to split, fails the whole analysis with a clear error.
    private func notesForPart(_ part: TranscriptChunk, system: String, context: String,
                              budget: AppleAnalysisBudget) async throws -> ChunkNotes {
        let firstError: LanguageModelSession.GenerationError
        do {
            return try await notes(system: system, prompt: UnifiedInsightsPrompt.chunkNotesUserPrompt(context: context, chunk: part),
                                   budget: budget, label: "part \(part.index)/\(part.total)")
        } catch let error as LanguageModelSession.GenerationError where Self.splitMayHelp(error) {
            firstError = error
        }
        let halves = TranscriptChunkPlanner.plan(
            part.text, maxTokensPerChunk: max(200, (AppleAnalysisBudget.estimateTokens(part.text) + 1) / 2),
            overlapLines: 0, countTokens: AppleAnalysisBudget.estimateTokens)
        guard halves.count > 1 else { throw Self.partFailure(part, firstError) }
        Self.diagnostic("part \(part.index)/\(part.total) failed (\(Self.caseName(firstError))); splitting into \(halves.count)")
        var merged = ChunkNotes(keyPoints: [], decisions: [], actionItems: [], people: [])
        for (offset, half) in halves.enumerated() {
            try Task.checkCancellation()
            let notes: ChunkNotes
            do {
                notes = try await self.notes(
                    system: system,
                    prompt: UnifiedInsightsPrompt.chunkNotesUserPrompt(
                        context: context, chunk: TranscriptChunk(index: part.index, total: part.total, text: half.text)),
                    budget: budget, label: "part \(part.index)/\(part.total) half \(offset + 1)/\(halves.count)")
            } catch let error as LanguageModelSession.GenerationError {
                throw Self.partFailure(part, error)
            }
            merged.keyPoints += notes.keyPoints
            merged.decisions += notes.decisions
            merged.actionItems += notes.actionItems
            merged.people += notes.people
        }
        return merged.deduplicated()
    }

    private func condense(_ group: [ChunkNotes], outputLanguage: OutputLanguage,
                          budget: AppleAnalysisBudget) async throws -> ChunkNotes {
        let input = ChunkNotesMerger.reduceInput(group, maxTokens: budget.reduceInputTokens,
                                                 countTokens: AppleAnalysisBudget.estimateTokens)
        do {
            let merged = try await notes(system: UnifiedInsightsPrompt.condenseNotesSystemPrompt(outputLanguage: outputLanguage),
                                         prompt: "NOTES TO MERGE:\n\(input)", budget: budget, label: "condense")
            return NotesReducePlanner.withoutActions([merged])[0]
        } catch let error as LanguageModelSession.GenerationError where Self.splitMayHelp(error) {
            // Keep the group's notes merged verbatim instead: nothing is dropped here, and
            // `ChunkNotesMerger.reduceInput` trims only key points if they don't fit.
            Self.diagnostic("condense failed (\(Self.caseName(error))); merging \(group.count) notes without the model")
            return NotesReducePlanner.merged(group)
        }
    }

    /// Guided notes (map or condense step). The on-device model sometimes refuses guided
    /// generation of benign meeting text ("May contain sensitive content") yet answers the
    /// same request as free text, so a refusal or guardrail block is retried once as text
    /// with permissive content-transformation guardrails and parsed by `ChunkNotesTextFormat`.
    private func notes(system: String, prompt: String, budget: AppleAnalysisBudget, label: String) async throws -> ChunkNotes {
        let refusal: LanguageModelSession.GenerationError
        do {
            return try await respond(instructions: system, prompt: prompt, generating: PartNotes.self,
                                     maxResponse: budget.notesResponseTokens).chunkNotes
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .refusal, .guardrailViolation: refusal = error
            default: throw error
            }
        }
        Self.diagnostic("\(label) refused as guided notes (\(Self.caseName(refusal))); retrying as text")
        let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                                           instructions: system + "\n\n" + ChunkNotesTextFormat.instruction)
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: budget.notesResponseTokens)
        let text = try await PrivacyTrace.perform(.init(stage: .analysis, data: [.text, .metadata],
                                                        destination: .local(provider: .appleIntelligence))) {
            try await session.respond(to: prompt, options: options).content
        }
        // A refusal sentence instead of notes: surface the original refusal.
        guard let notes = ChunkNotesTextFormat.parse(text) else {
            Self.diagnostic("\(label) refused as text too")
            throw refusal
        }
        return notes
    }

    private func respond<T: Generable>(instructions: String, prompt: String, generating: T.Type,
                                       maxResponse: Int) async throws -> T {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: maxResponse)
        return try await PrivacyTrace.perform(.init(stage: .analysis, data: [.text, .metadata],
                                                    destination: .local(provider: .appleIntelligence))) {
            try await session.respond(to: prompt, generating: T.self, options: options).content
        }
    }

    /// Content-dependent failures a smaller part can avoid; availability, rate-limit and
    /// language errors would only fail again.
    private static func splitMayHelp(_ error: LanguageModelSession.GenerationError) -> Bool {
        switch error {
        case .exceededContextWindowSize, .decodingFailure, .guardrailViolation, .refusal: true
        default: false
        }
    }

    private static func partFailure(_ part: TranscriptChunk, _ error: LanguageModelSession.GenerationError) -> LocalAIError {
        diagnostic("part \(part.index)/\(part.total) failed after splitting (\(caseName(error)))")
        return .generation("Apple Intelligence could not analyze part \(part.index) of \(part.total) of this recording, even after splitting it. \(describe(error))")
    }

    /// The error's case name only: a `GenerationError`'s description can quote transcript text.
    private static func caseName(_ error: LanguageModelSession.GenerationError) -> String {
        String(String(describing: error).prefix(while: { $0 != "(" }))
    }

    /// Map-reduce diagnostics: unified log plus stderr, so the eval harness sees them.
    /// Messages carry counts, stages and error case names only, never transcript text.
    private static func diagnostic(_ message: String) {
        log.warning("Apple Intelligence \(message, privacy: .public)")
        FileHandle.standardError.write(Data("LocalAIService: \(message)\n".utf8))
    }

    /// A fresh session for a standalone prompt task; never uses recording history.
    func completeText(systemPrompt: String, userMessage: String, stage: PrivacyOperation.Stage) async throws -> String {
        try Task.checkCancellation()
        try Self.ensureAvailable()
        let session = LanguageModelSession(instructions: systemPrompt)
        do {
            let response = try await PrivacyTrace.perform(.init(stage: stage, data: [.text, .metadata], destination: .local(provider: .appleIntelligence))) {
                try await session.respond(to: userMessage, options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 2_000))
            }
            try Task.checkCancellation()
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw PromptAIError.contextLimit
            case .guardrailViolation: throw LocalAIError.generation("Apple Intelligence could not process this request because of its safety guardrails.")
            case .unsupportedLanguageOrLocale: throw LocalAIError.generation("Apple Intelligence does not support this language. Choose a different engine.")
            default: throw LocalAIError.generation("Apple Intelligence could not complete the request. Try again or choose a different engine.")
            }
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
            return "Part of this recording was too dense for Apple Intelligence even after splitting. Try a different AI engine."
        case .guardrailViolation:
            return "Apple Intelligence blocked this content with its safety guardrails."
        case .unsupportedLanguageOrLocale:
            return "Apple Intelligence does not support this language. Choose a different output language or AI engine."
        case .decodingFailure:
            return "Apple Intelligence returned an incomplete result. Try again or choose a different AI engine."
        case .refusal:
            return "Apple Intelligence declined to analyze this content. Try again or choose a different AI engine."
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
