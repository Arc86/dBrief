import Foundation
import Testing
import dBriefWire
@testable import dBrief

#if canImport(FoundationModels)
/// Apple Intelligence long-transcript chat eval. Opt-in only (it calls the on-device model
/// and reads private transcript content), driven by scripts/chat-eval.py `--engine apple`:
/// `DBRIEF_APPLE_EVAL=1 DBRIEF_EVAL_INDEX=<~/gemma-eval/…json> DBRIEF_APPLE_EVAL_OUT=<json>
/// [DBRIEF_APPLE_EVAL_CONFIGS=default,p40,baseline] swift test --filter AppleChatEvalTests`.
///
/// The index is the helper's `--dump-index` JSON (windows, document/query vectors, summary,
/// action items, part notes, transcript), so no ML helper runs here. Results go to the OUT
/// file, never stdout, because they hold answer text.
///
/// Configs: `default` = the shipped profile (excerpts 30% / overview 25% of the context window);
/// `p40` = the earlier split, excerpts 40% / overview 15%; `baseline` = the old behaviour (head + tail of the transcript through
/// `truncateForFoundationModels`, no retrieval).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBRIEF_APPLE_EVAL"] == "1"))
struct AppleChatEvalTests {
    struct Dump: Decodable {
        struct Query: Decodable { let q: String; let vector: [Float] }
        let windows: [TranscriptWindow]
        let vectors: [[Float]]
        let queries: [Query]
        let summary: String
        let actionItems: [String]
        let partNotes: [ChunkNotes]?
        let transcript: String?
    }

    @available(macOS 26, *)
    @Test func answersPlantedQuestions() async throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["DBRIEF_EVAL_INDEX"])
        let outPath = try #require(env["DBRIEF_APPLE_EVAL_OUT"])
        let dump = try JSONDecoder().decode(Dump.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let configs = (env["DBRIEF_APPLE_EVAL_CONFIGS"] ?? "default").split(separator: ",").map(String.init)
        let count = ChatEngineProfile.estimateTokens
        let base = AppleChatBackend.profile

        func profile(for config: String) -> ChatEngineProfile {
            guard config == "p40" else { return base }
            let size = base.excerptTokens * 100 / 30 // the context window
            return ChatEngineProfile(fullTranscriptTokens: base.fullTranscriptTokens, excerptTokens: size * 40 / 100,
                                     overviewTokens: size * 15 / 100, historyTokens: base.historyTokens,
                                     scanPartTokens: base.scanPartTokens, scanFindingsTokens: base.scanFindingsTokens,
                                     reusesSession: false)
        }

        func ask(config: String, profile: ChatEngineProfile, query: Dump.Query) async throws -> (answer: String, excerptTokens: Int) {
            if config == "baseline" {
                let transcript = try #require(dump.transcript)
                let instructions = "You are an assistant analyzing a meeting transcript. The transcript is included below. "
                    + "Answer from it only.\n\n===== TRANSCRIPT =====\n"
                    + UnifiedInsightsPrompt.truncateForFoundationModels(transcript) + "\n===== END ====="
                return (try await AppleChatBackend.respond(instructions: instructions, prompt: query.q), 0)
            }
            let overview = ChatOverview.make(notes: dump.partNotes, summary: dump.summary, actionItems: dump.actionItems,
                                             budget: profile.overviewTokens, countTokens: count)
            let excerpts = TranscriptRetrieval.hybridExcerpts(
                question: query.q, queryVector: query.vector, windows: dump.windows, vectors: dump.vectors,
                budgetTokens: profile.excerptTokens, countTokens: count)
            let answer = try await AppleChatBackend.respond(
                instructions: ChatContextPlanner.longModeSystemPrompt(overview: overview, speakerLegend: ""),
                prompt: ChatContextPlanner.freshSessionPrompt(history: "", excerpts: excerpts, question: query.q))
            return (answer, count(excerpts))
        }

        var results: [[String: Any]] = []
        for config in configs {
            let cfg = profile(for: config)
            var rows: [[String: Any]] = []
            for query in dump.queries {
                let start = ContinuousClock.now
                var attempt = AppleChatAttempt.first
                var row: [String: Any] = ["q": query.q]
                while true {
                    do {
                        let result = try await ask(config: config, profile: attempt == .first ? cfg : cfg.shrunk(), query: query)
                        row["answer"] = result.answer
                        row["excerpt_tokens"] = result.excerptTokens
                        break
                    } catch {
                        guard let next = AppleChatAttempt.next(after: error, attempt: attempt,
                                                               isOverflow: AppleChatBackend.isContextOverflow) else {
                            row["error"] = String(describing: AppleGenerationFailure.classify(error)?.description ?? "other")
                            break
                        }
                        row["overflow_retry"] = true
                        attempt = next
                    }
                }
                let elapsed = ContinuousClock.now - start
                row["total_s"] = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                rows.append(row)
            }
            results.append(["config": config, "excerpt_budget": cfg.excerptTokens, "overview_budget": cfg.overviewTokens,
                            "answers": rows])
        }
        try JSONSerialization.data(withJSONObject: ["mode": "apple-long", "configs": results])
            .write(to: URL(fileURLWithPath: outPath), options: .atomic)
    }
}
#endif
