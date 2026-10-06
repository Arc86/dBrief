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

    /// Notes for one transcript part (map step). Declared actions-first: generation
    /// follows declaration order, so the high-value lists are produced before the
    /// open-ended key-points list can run long. List caps bound the response so it fits
    /// `notesResponseTokens`; `listsAtCap` reports a list that may have been cut short.
    @Generable
    struct PartNotes: AppleNotesSchema {
        @Guide(description: "Only explicit commitments, following the action_items rule in the instructions; usually none, or one or two. One short line each (at most 20 words), keeping the speaker's wording for the task.", .maximumCount(10))
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

        var listsAtCap: [String] {
            [("action items", actionItems.count, 10), ("decisions", decisions.count, 8),
             ("people", people.count, 12), ("key points", keyPoints.count, 10)]
                .filter { $0.1 >= $0.2 }.map(\.0)
        }
    }

    /// Condense step: merges several parts' notes. No action items (merged deterministically
    /// from the map notes) and room for every decision the parts carry.
    @Generable
    struct CondensedNotes: AppleNotesSchema {
        @Guide(description: "Every decision or agreement in the notes, one short sentence each.", .maximumCount(40))
        var decisions: [String]

        @Guide(description: "Only the names of everyone in the notes.", .maximumCount(30))
        var people: [String]

        @Guide(description: "The distinct topics, facts, numbers, names and concerns in the notes, one short specific sentence each (at most 25 words).", .maximumCount(10))
        var keyPoints: [String]

        var chunkNotes: ChunkNotes {
            ChunkNotes(keyPoints: keyPoints, decisions: decisions, actionItems: [], people: people).deduplicated()
        }

        var listsAtCap: [String] {
            [("decisions", decisions.count, 40), ("people", people.count, 30), ("key points", keyPoints.count, 10)]
                .filter { $0.1 >= $0.2 }.map(\.0)
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

    /// Labels for a summary written as free text (the reduce fallback after a refusal).
    @Generable
    struct MeetingLabels {
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
                do {
                    return try await singlePass(full, outputLanguage: outputLanguage, customVocabulary: customVocabulary,
                                                guidance: guidance, maxResponse: budget.finalResponseTokens)
                } catch where AppleGenerationFailure.classify(error) == .overflow {
                    // Long instructions (user guidance) can overflow a transcript that fits on its own.
                    Self.diagnostic("single pass overflowed; using map-reduce")
                }
            }
            return try await mapReduce(transcript, context: context, budget: budget, outputLanguage: outputLanguage,
                                       customVocabulary: customVocabulary, guidance: guidance)
        } catch where AppleGenerationFailure.classify(error) != nil {
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
            outputLanguage: outputLanguage, customVocabulary: customVocabulary, guidance: guidance,
            commitments: .explicitOnly)

        var notes: [ChunkNotes] = []
        for part in parts {
            try Task.checkCancellation()
            MLProgress.sink?(.analyzingPart(index: part.index, total: part.total))
            notes.append(try await notesForPart(part, system: mapSystem, context: context, budget: budget))
        }

        EvalNotesDump.write(notes)
        // Hierarchical reduce: condense consecutive notes until they fit one reduce prompt
        // (which also carries the context).
        try Task.checkCancellation()
        MLProgress.sink?(.analyzingPart(index: parts.count + 1, total: parts.count))
        let notesBudget = max(400, budget.reduceInputTokens - contextTokens)
        var level = NotesReducePlanner.withoutActions(notes)
        while true {
            let groups = NotesReducePlanner.groups(level, budget: notesBudget, countTokens: AppleAnalysisBudget.estimateTokens)
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
        let notesText = ChunkNotesMerger.reduceInput(level, maxTokens: notesBudget, countTokens: AppleAnalysisBudget.estimateTokens)
        try Task.checkCancellation()
        let record = try await finalRecord(
            instructions: UnifiedInsightsPrompt.reduceSystemPrompt(outputLanguage: outputLanguage, customVocabulary: customVocabulary,
                                                                   guidance: guidance, forGuidedGeneration: true),
            prompt: UnifiedInsightsPrompt.reduceUserPrompt(context: context, notes: notesText), budget: budget)
        try Task.checkCancellation()
        let actionItems = ChunkNotesMerger.mergedActionItems(notes)
        log.info("Apple Intelligence map-reduce complete: parts=\(parts.count) summaryLength=\(record.summary.count) actions=\(actionItems.count)")
        return LocalInsightsResult(titleConcept: record.titleConcept, summary: record.summary,
                                   actionItems: actionItems, tags: record.tags, sentiment: record.sentiment)
    }

    private struct FinalRecord { let summary: String, tags: [String], sentiment: String, titleConcept: String }

    /// The guided final record. If the model refuses it (as it does for some benign
    /// meetings), the summary is written as free text with permissive guardrails and the
    /// labels are generated from that summary; a refusal there too fails loudly.
    private func finalRecord(instructions: String, prompt: String, budget: AppleAnalysisBudget) async throws -> FinalRecord {
        let refusal: Error
        do {
            let r = try await respond(instructions: instructions, prompt: prompt, generating: MeetingRecord.self,
                                      maxResponse: budget.finalResponseTokens)
            return FinalRecord(summary: r.summary, tags: r.tags, sentiment: r.sentiment.canonical, titleConcept: r.titleConcept)
        } catch {
            guard let failure = AppleGenerationFailure.classify(error) else { throw error }
            Self.diagnostic("final record failed (\(failure))")
            guard failure.retryAsText else { throw error }
            refusal = error
        }
        try Task.checkCancellation()
        Self.diagnostic("writing the summary as text")
        let summary = try await permissiveText(
            instructions: instructions + "\n\nWrite only the meeting summary, as the SUMMARY rule requires. No title, tags or sentiment.",
            prompt: prompt, maxResponse: budget.finalResponseTokens)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, !RefusalText.isRefusal(summary) else {
            Self.diagnostic("summary refused as text too")
            throw refusal
        }
        try Task.checkCancellation()
        let labels: MeetingLabels
        do {
            labels = try await respond(instructions: instructions, prompt: "MEETING SUMMARY:\n\(summary)",
                                       generating: MeetingLabels.self, maxResponse: budget.notesResponseTokens)
        } catch where AppleGenerationFailure.classify(error)?.retryAsText == true {
            Self.diagnostic("labels refused")
            throw refusal
        }
        return FinalRecord(summary: summary, tags: labels.tags, sentiment: labels.sentiment.canonical,
                           titleConcept: labels.titleConcept)
    }

    /// Free-text generation with permissive content-transformation guardrails (fallbacks only).
    private func permissiveText(instructions: String, prompt: String, maxResponse: Int) async throws -> String {
        let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                                           instructions: instructions)
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: maxResponse)
        return try await PrivacyTrace.perform(.init(stage: .analysis, data: [.text, .metadata],
                                                    destination: .local(provider: .appleIntelligence))) {
            try await session.respond(to: prompt, options: options).content
        }
    }

    /// Notes for one part. When the part fails (overflows the window, its notes run past
    /// the response cap and fail to decode, or it is refused even as text), it is split
    /// once into halves and each half is mapped, so no part is ever skipped. A half that
    /// still fails, or a part too small to split, fails the whole analysis with a clear error.
    private func notesForPart(_ part: TranscriptChunk, system: String, context: String,
                              budget: AppleAnalysisBudget) async throws -> ChunkNotes {
        let firstError: Error
        let firstFailure: AppleGenerationFailure
        do {
            return try await notes(PartNotes.self, system: system,
                                   prompt: UnifiedInsightsPrompt.chunkNotesUserPrompt(context: context, chunk: part),
                                   budget: budget, label: "part \(part.index)/\(part.total)")
        } catch {
            guard let failure = AppleGenerationFailure.classify(error), failure.splitMayHelp else { throw error }
            (firstError, firstFailure) = (error, failure)
        }
        let halves = TranscriptChunkPlanner.plan(
            part.text, maxTokensPerChunk: max(200, (AppleAnalysisBudget.estimateTokens(part.text) + 1) / 2),
            overlapLines: 0, countTokens: AppleAnalysisBudget.estimateTokens)
        guard halves.count > 1 else { throw Self.partFailure(part, firstError) }
        Self.diagnostic("part \(part.index)/\(part.total) failed (\(firstFailure)); splitting into \(halves.count)")
        var merged = ChunkNotes(keyPoints: [], decisions: [], actionItems: [], people: [])
        for (offset, half) in halves.enumerated() {
            try Task.checkCancellation()
            let notes: ChunkNotes
            do {
                notes = try await self.notes(
                    PartNotes.self, system: system,
                    prompt: UnifiedInsightsPrompt.chunkNotesUserPrompt(
                        context: context, chunk: TranscriptChunk(index: part.index, total: part.total, text: half.text)),
                    budget: budget, label: "part \(part.index)/\(part.total) half \(offset + 1)/\(halves.count)")
            } catch where AppleGenerationFailure.classify(error) != nil {
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
            let merged = try await notes(CondensedNotes.self,
                                         system: UnifiedInsightsPrompt.condenseNotesSystemPrompt(outputLanguage: outputLanguage),
                                         prompt: "NOTES TO MERGE:\n\(input)", budget: budget, label: "condense")
            return NotesReducePlanner.withoutActions([merged])[0]
        } catch {
            guard let failure = AppleGenerationFailure.classify(error), failure.splitMayHelp else { throw error }
            // Keep the group's notes merged verbatim instead: nothing is dropped here, and
            // `ChunkNotesMerger.reduceInput` trims only key points if they don't fit.
            Self.diagnostic("condense failed (\(failure)); merging \(group.count) notes without the model")
            return NotesReducePlanner.merged(group)
        }
    }

    /// Guided notes (map or condense step). The on-device model sometimes refuses guided
    /// generation of benign meeting text ("May contain sensitive content") yet answers the
    /// same request as free text, so a refusal or guardrail block is retried once as text
    /// with permissive content-transformation guardrails and parsed by `ChunkNotesTextFormat`.
    private func notes<Schema: AppleNotesSchema>(_ schema: Schema.Type, system: String, prompt: String,
                                                  budget: AppleAnalysisBudget, label: String) async throws -> ChunkNotes {
        let refusal: Error
        do {
            let result = try await respond(instructions: system, prompt: prompt, generating: Schema.self,
                                           maxResponse: budget.notesResponseTokens)
            let capped = result.listsAtCap
            if !capped.isEmpty { Self.diagnostic("\(label) reached the list cap: \(capped.joined(separator: ", "))") }
            return result.chunkNotes
        } catch {
            guard let failure = AppleGenerationFailure.classify(error), failure.retryAsText else { throw error }
            Self.diagnostic("\(label) refused as guided notes (\(failure)); retrying as text")
            refusal = error
        }
        let text = try await permissiveText(instructions: system + "\n\n" + ChunkNotesTextFormat.instruction,
                                            prompt: prompt, maxResponse: budget.notesResponseTokens)
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

    private static func partFailure(_ part: TranscriptChunk, _ error: Error) -> LocalAIError {
        diagnostic("part \(part.index)/\(part.total) failed after splitting (\(AppleGenerationFailure.classify(error).map { "\($0)" } ?? "unknown"))")
        return .generation("Apple Intelligence could not analyze part \(part.index) of \(part.total) of this recording, even after splitting it. \(describe(error))")
    }

    /// Map-reduce diagnostics: unified log plus stderr, so the eval harness sees them.
    /// Messages carry counts, stages and error kinds only, never transcript text.
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

    private static func describe(_ error: Error) -> String {
        AppleGenerationFailure.classify(error)?.message ?? error.localizedDescription
    }
}

/// A guided notes schema for the map-reduce path (`PartNotes`, `CondensedNotes`).
@available(macOS 26, *)
protocol AppleNotesSchema: Generable {
    var chunkNotes: ChunkNotes { get }
    /// Names of the lists that came back exactly at their `.maximumCount` (possibly cut short).
    var listsAtCap: [String] { get }
}

/// FoundationModels failures, classified once so the split, text-fallback and message
/// decisions don't depend on which error type the OS throws: macOS 26 uses
/// `LanguageModelSession.GenerationError`; macOS 27 deprecates it in favour of
/// `LanguageModelError` and `GeneratedContent.ParsingError`.
@available(macOS 26, *)
enum AppleGenerationFailure: Equatable, CustomStringConvertible {
    case overflow, refusal, guardrail, decoding, unsupportedLanguage, other

    /// `nil` for errors that are not model failures (cancellation, our own errors).
    static func classify(_ error: Error) -> AppleGenerationFailure? {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .overflow
            case .refusal: return .refusal
            case .guardrailViolation: return .guardrail
            case .decodingFailure: return .decoding
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            default: return .other
            }
        }
        if #available(macOS 27, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return .overflow
                case .refusal: return .refusal
                case .guardrailViolation: return .guardrail
                case .unsupportedLanguageOrLocale: return .unsupportedLanguage
                default: return .other
                }
            }
            if error is GeneratedContent.ParsingError { return .decoding }
        }
        return nil
    }

    /// Content-dependent failures a smaller part can avoid; availability, rate-limit and
    /// language errors would only fail again.
    var splitMayHelp: Bool {
        switch self {
        case .overflow, .refusal, .guardrail, .decoding: true
        case .unsupportedLanguage, .other: false
        }
    }

    /// The model sometimes refuses guided generation of benign text but answers as free text.
    var retryAsText: Bool { self == .refusal || self == .guardrail }

    /// User-facing message; `nil` falls back to the error's own description.
    var message: String? {
        switch self {
        case .overflow: "Part of this recording was too dense for Apple Intelligence even after splitting. Try a different AI engine."
        case .refusal: "Apple Intelligence declined to analyze this content. Try again or choose a different AI engine."
        case .guardrail: "Apple Intelligence blocked this content with its safety guardrails."
        case .decoding: "Apple Intelligence returned an incomplete result. Try again or choose a different AI engine."
        case .unsupportedLanguage: "Apple Intelligence does not support this language. Choose a different output language or AI engine."
        case .other: nil
        }
    }

    var description: String {
        switch self {
        case .overflow: "overflow"
        case .refusal: "refusal"
        case .guardrail: "guardrail"
        case .decoding: "decoding"
        case .unsupportedLanguage: "unsupportedLanguage"
        case .other: "other"
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
