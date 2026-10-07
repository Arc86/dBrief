import Foundation
import dBriefWire
import MLXLMCommon

/// `--eval-insights <file>`: one Gemma analysis outside the request loop, for
/// measuring long-context behavior (see scripts/gemma-eval.py). Dev tooling only.
enum GemmaEval {
    static func run(arguments args: [String], output: FileHandle) async -> Int32 {
        guard let i = args.firstIndex(of: "--eval-insights"), i + 1 < args.count else { return 2 }
        let language: OutputLanguage = {
            guard let l = args.firstIndex(of: "--language"), l + 1 < args.count else { return .matchInput }
            switch args[l + 1] { case "en": return .english; case "nl": return .dutch; default: return .matchInput }
        }()
        EvalNotesDump.evalModeEnabled = true
        do {
            let text = try String(contentsOfFile: args[i + 1], encoding: .utf8)
            let service = MLXInsightsService(stateHandler: { state in
                FileHandle.standardError.write(Data("state: \(state)\n".utf8))
            })
            let start = ContinuousClock.now
            let result = try await service.analyzeTranscript(text, context: "", outputLanguage: language)
            let elapsed = ContinuousClock.now - start
            let resultJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
            let report: [String: Any] = [
                "elapsed_s": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                "peak_memory_mb": MLXInsightsService.peakMemoryBytes() / 1_048_576,
                "input_chars": text.count,
                "result": resultJSON,
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            output.write(data + Data("\n".utf8))
            return 0
        } catch {
            let data = (try? JSONSerialization.data(withJSONObject: ["error": "\(error)"])) ?? Data()
            output.write(data + Data("\n".utf8))
            return 1
        }
    }

    /// `--eval-chat <transcript> --questions <q.json> [--mode full|long] [--fresh-session-per-question]
    /// [--dump-index <~/gemma-eval/…json>]`: asks each question against the full transcript
    /// (`full`) or through long mode (`long`, see `runLongChat`) and reports timings. Dev tooling only.
    static func runChat(arguments args: [String], output: FileHandle) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let path = value("--eval-chat"), let qPath = value("--questions") else { return 2 }
        switch value("--mode") ?? "full" {
        case "full": break
        case "long": return await runLongChat(path: path, questionsPath: qPath, dumpPath: value("--dump-index"), output: output)
        default: return 2
        }
        let fresh = args.contains("--fresh-session-per-question")
        do {
            let transcript = try String(contentsOfFile: path, encoding: .utf8)
            let questions = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: qPath)))
            let service = MLXInsightsService(stateHandler: { _ in })
            let system = fullModePrompt(transcript)
            // Reuse path: the production GemmaChatSessions with a growing history,
            // so the real cache key decides reuse vs rebuild. This eval owns the
            // service exclusively, so the idle drop may call drop() directly.
            let sessions = GemmaChatSessions(insights: service) { await $0.drop() }
            var history: [ChatTurnMessage] = []
            var answers: [[String: Any]] = []
            for q in questions {
                let start = ContinuousClock.now
                let collector = DeltaCollector(start: start)
                if fresh {
                    let container = try await service.loadForChat()
                    let session = ChatSession(container, instructions: system, generateParameters: service.chatGenerationParameters())
                    for try await chunk in session.streamResponse(to: q) { collector.append(chunk) }
                    await session.synchronize()
                } else {
                    try await sessions.respond(systemPrompt: system, history: history, question: q,
                                               onDelta: { collector.append($0) })
                }
                let total = ContinuousClock.now - start
                let (answer, first) = collector.result
                history += [ChatTurnMessage(role: .user, content: q), ChatTurnMessage(role: .assistant, content: answer)]
                answers.append(["q": q, "answer": answer,
                                "first_token_s": seconds(first ?? total), "total_s": seconds(total)])
            }
            let report: [String: Any] = ["mode": fresh ? "full-fresh" : "full", "answers": answers,
                                         "input_chars": transcript.count,
                                         "peak_memory_mb": MLXInsightsService.peakMemoryBytes() / 1_048_576]
            output.write(try JSONSerialization.data(withJSONObject: report) + Data("\n".utf8))
            return 0
        } catch {
            let data = (try? JSONSerialization.data(withJSONObject: ["error": "\(error)"])) ?? Data()
            output.write(data + Data("\n".utf8))
            return 1
        }
    }

    struct DumpPathOutsideEvalDir: Error, CustomStringConvertible {
        let path: String
        var description: String { "--dump-index must be under ~/gemma-eval/ (it holds transcript text): \(path)" }
    }

    /// Long mode as Transcript Chat runs it for a finished long recording on Gemma:
    /// map-reduce analysis first (for part notes, like processing does), then the
    /// overview, windows and an in-process e5 index, then each question through
    /// `GemmaChatSessions.respond(…, retrievedContext:)` with one stable system prompt.
    /// `first_token_s`/`total_s` include the query embedding and retrieval.
    private static func runLongChat(path: String, questionsPath: String, dumpPath: String?,
                                    output: FileHandle) async -> Int32 {
        do {
            let dumpURL = try dumpPath.map(evalDumpURL)
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let questions = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: questionsPath)))
            let service = MLXInsightsService(stateHandler: { _ in })
            let profile = ChatEngineProfile.gemma
            let count = ChatEngineProfile.estimateTokens

            var clock = ContinuousClock.now
            let insights = try await service.analyzeTranscript(text, context: "", outputLanguage: .matchInput)
            let analysisElapsed = ContinuousClock.now - clock

            let turns = retrievalTurns(text)
            let transcriptTokens = count(ChatTranscript.format(turns))
            let overview = ChatOverview.make(notes: insights.partNotes, summary: insights.summary,
                                             actionItems: insights.actionItems, budget: profile.overviewTokens,
                                             countTokens: count)
            let plannedMode = ChatContextPlanner.mode(transcriptTokens: transcriptTokens, profile: profile,
                                                      hasOverview: !overview.isEmpty)
            let windows = TranscriptRetrieval.windows(turns, targetTokens: 350, overlapTurns: 1, countTokens: count)
            let embedder = EmbeddingService(stateHandler: { state in
                FileHandle.standardError.write(Data("state: \(state)\n".utf8))
            })
            clock = ContinuousClock.now
            let vectors = try await embedder.embed(windows.map(\.text), role: .document)
            let indexElapsed = ContinuousClock.now - clock

            // Speaker names are inline in each line; the eval transcript has no label IDs.
            let system = ChatContextPlanner.longModeSystemPrompt(overview: overview, speakerLegend: "")
            let sessions = GemmaChatSessions(insights: service) { await $0.drop() }
            var history: [ChatTurnMessage] = []
            var answers: [[String: Any]] = []
            var queries: [[String: Any]] = []
            for q in questions {
                let start = ContinuousClock.now
                let collector = DeltaCollector(start: start)
                let qv = try await embedder.embed([q], role: .query).first
                let found = TranscriptRetrieval.hybridExcerpts(question: q, queryVector: qv, windows: windows,
                                                               vectors: vectors, budgetTokens: profile.excerptTokens,
                                                               countTokens: count)
                try await sessions.respond(systemPrompt: system, history: history, question: q,
                                           retrievedContext: ChatContextPlanner.retrievedContextBlock(found),
                                           onDelta: { collector.append($0) })
                let total = ContinuousClock.now - start
                let (answer, first) = collector.result
                history += [ChatTurnMessage(role: .user, content: q), ChatTurnMessage(role: .assistant, content: answer)]
                answers.append(["q": q, "answer": answer, "excerpt_tokens": count(found),
                                "first_token_s": seconds(first ?? total), "total_s": seconds(total)])
                queries.append(["q": q, "vector": qv ?? []])
            }
            await embedder.unload()

            if let dumpURL {
                let dump: [String: Any] = [
                    "model": EmbeddingPrompt.current.id,
                    "windows": windows.map { ["index": $0.index, "start": $0.start, "end": $0.end, "text": $0.text] },
                    "vectors": vectors, "queries": queries,
                    "summary": insights.summary, "actionItems": insights.actionItems,
                    "partNotes": try JSONSerialization.jsonObject(with: JSONEncoder().encode(insights.partNotes ?? [])),
                ]
                try FileManager.default.createDirectory(at: dumpURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: dump).write(to: dumpURL, options: .atomic)
            }

            let overviewSource = overview.hasPrefix("MEETING NOTES") ? "notes" : (overview.isEmpty ? "none" : "summary")
            let report: [String: Any] = [
                "mode": "long", "planned_mode": "\(plannedMode)", "answers": answers,
                "input_chars": text.count, "transcript_tokens": transcriptTokens,
                "windows": windows.count, "part_notes": insights.partNotes?.count ?? 0,
                "overview_source": overviewSource, "overview_tokens": count(overview),
                "analysis_s": seconds(analysisElapsed), "index_s": seconds(indexElapsed),
                "peak_memory_mb": MLXInsightsService.peakMemoryBytes() / 1_048_576,
            ]
            output.write(try JSONSerialization.data(withJSONObject: report) + Data("\n".utf8))
            return 0
        } catch {
            let data = (try? JSONSerialization.data(withJSONObject: ["error": "\(error)"])) ?? Data()
            output.write(data + Data("\n".utf8))
            return 1
        }
    }

    /// The index dump holds private transcript text, so it may only go under ~/gemma-eval/.
    /// Symlinks are resolved on the root and on the target's parent, so a symlinked
    /// ~/gemma-eval works and a link out of it is rejected.
    static func evalDumpURL(_ path: String) throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("gemma-eval", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let url = target.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(target.lastPathComponent)
        guard url.path.hasPrefix(root) else { throw DumpPathOutsideEvalDir(path: path) }
        return url
    }

    /// `--eval-embed <query> <doc> [<doc>…] [--embed-model <hf-id>]`: embeds the query
    /// (query role) and each doc (document role) and reports cosine(query, doc) per doc.
    /// Dev tooling only (retrieval smoke test).
    static func runEmbed(arguments args: [String], output: FileHandle) async -> Int32 {
        guard let i = args.firstIndex(of: "--eval-embed"), args.count > i + 2 else { return 2 }
        let query = args[i + 1]
        let docs = Array(args[(i + 2)...].prefix { !$0.hasPrefix("--") })
        do {
            let service = EmbeddingService(spec: try embedSpec(args), stateHandler: { state in
                FileHandle.standardError.write(Data("state: \(state)\n".utf8))
            })
            let start = ContinuousClock.now
            let q = try await service.embed([query], role: .query)[0]
            let d = try await service.embed(docs, role: .document)
            let elapsed = ContinuousClock.now - start
            let sims = d.map { cosine(q, $0) }
            let report: [String: Any] = [
                "model": service.spec.id, "query": query, "docs": docs, "dims": q.count,
                "similarities": sims, "elapsed_s": seconds(elapsed),
            ]
            output.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data("\n".utf8))
            return 0
        } catch {
            let data = (try? JSONSerialization.data(withJSONObject: ["error": "\(error)"])) ?? Data()
            output.write(data + Data("\n".utf8))
            return 1
        }
    }

    /// The 3 planted needles (scripts/gemma-eval.py) and the chat questions that target them.
    static let retrievalNeedles: [(question: String, probe: String)] = [
        ("Who is sending the Kestrel vendor contract to legal, and by when?", "kestrel"),
        ("What was decided about the Halcyon launch date?", "halcyon"),
        ("What will Priya share next Monday?", "brightwater"),
    ]

    /// `--eval-retrieval <planted-transcript.txt> [--embed-model <hf-id>]`: windows the
    /// transcript like transcript chat, then reports the 1-based rank of the best window
    /// holding each needle under cosine, BM25 and the fused (RRF) ranking. Never prints
    /// window text. Dev tooling only.
    static func runRetrieval(arguments args: [String], output: FileHandle) async -> Int32 {
        guard let i = args.firstIndex(of: "--eval-retrieval"), i + 1 < args.count else { return 2 }
        do {
            let spec = try embedSpec(args)
            let text = try String(contentsOfFile: args[i + 1], encoding: .utf8)
            let turns = retrievalTurns(text)
            let windows = TranscriptRetrieval.windows(turns, targetTokens: 350, overlapTurns: 1,
                                                      countTokens: { ($0.count + 2) / 3 })
            let service = EmbeddingService(spec: spec, stateHandler: { state in
                FileHandle.standardError.write(Data("state: \(state)\n".utf8))
            })
            let start = ContinuousClock.now
            let docVectors = try await service.embed(windows.map(\.text), role: .document)
            let docElapsed = ContinuousClock.now - start
            let queryVectors = try await service.embed(retrievalNeedles.map(\.question), role: .query)
            var results: [[String: Any]] = []
            for ((question, probe), q) in zip(retrievalNeedles, queryVectors) {
                let holders = Set(windows.filter { $0.text.lowercased().contains(probe) }.map(\.index))
                let cosine = TranscriptRetrieval.cosineRanking(query: q, vectors: docVectors)
                let bm25 = TranscriptRetrieval.bm25Ranking(query: question, windows: windows)
                let fused = TranscriptRetrieval.fuse([Array(cosine.prefix(30)), Array(bm25.prefix(30))])
                func rank(_ ranking: [Int]) -> Any {
                    ranking.firstIndex(where: holders.contains).map { $0 + 1 } ?? NSNull()
                }
                results.append(["probe": probe, "needle_windows": holders.count,
                                "cosine": rank(cosine), "bm25": rank(bm25), "fused": rank(fused)])
            }
            let report: [String: Any] = [
                "model": spec.id, "dims": docVectors.first?.count ?? 0,
                "turns": turns.count, "windows": windows.count,
                "embed_docs_s": seconds(docElapsed), "elapsed_s": seconds(ContinuousClock.now - start),
                "peak_memory_mb": MLXInsightsService.peakMemoryBytes() / 1_048_576,
                "needles": results,
            ]
            output.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data("\n".utf8))
            return 0
        } catch {
            let data = (try? JSONSerialization.data(withJSONObject: ["error": "\(error)"])) ?? Data()
            output.write(data + Data("\n".utf8))
            return 1
        }
    }

    /// One turn per non-empty line ("Name: text", else unattributed), 10 s apart so
    /// every turn has a distinct timestamp.
    static func retrievalTurns(_ text: String) -> [TranscriptTurn] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, line in
                let start = Double(index) * 10
                if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 40 {
                    let speaker = line[..<colon].trimmingCharacters(in: .whitespaces)
                    let body = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !speaker.isEmpty, !body.isEmpty {
                        return TranscriptTurn(start: start, end: start + 10, speaker: speaker, text: body)
                    }
                }
                return TranscriptTurn(start: start, end: start + 10, speaker: nil, text: line)
            }
    }

    struct UnknownEmbedModel: Error, CustomStringConvertible {
        let id: String
        var description: String {
            "unknown --embed-model \(id); known: \(EmbeddingModelSpec.known.map(\.id).joined(separator: ", "))"
        }
    }

    /// `--embed-model <hf-id>` (one of `EmbeddingModelSpec.known`), else the production model.
    private static func embedSpec(_ args: [String]) throws -> EmbeddingModelSpec {
        guard let i = args.firstIndex(of: "--embed-model"), i + 1 < args.count else { return EmbeddingPrompt.current }
        guard let spec = EmbeddingModelSpec.named(args[i + 1]) else { throw UnknownEmbedModel(id: args[i + 1]) }
        return spec
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for (x, y) in zip(a, b) { dot += x * y; na += x * x; nb += y * y }
        return Double(dot / max((na * nb).squareRoot(), 1e-12))
    }

    /// Accumulates streamed deltas and the time to the first one (`onDelta` is @Sendable).
    private final class DeltaCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let start: ContinuousClock.Instant
        private var text = ""
        private var first: Duration?
        init(start: ContinuousClock.Instant) { self.start = start }
        func append(_ chunk: String) {
            lock.withLock {
                if first == nil { first = ContinuousClock.now - start }
                text += chunk
            }
        }
        var result: (String, Duration?) { lock.withLock { (text, first) } }
    }

    /// Same wording as TranscriptChatService.buildSystemPrompt (full-transcript mode).
    private static func fullModePrompt(_ transcript: String) -> String {
        "You are an assistant analyzing a meeting transcript. The complete transcript is included in full below — "
            + "you already have it. Never ask the user to provide the transcript; always answer from the text between the markers.\n\n"
            + "===== TRANSCRIPT START =====\n\(transcript)\n===== TRANSCRIPT END =====\n"
            + "\nAnswer concisely in the transcript's language."
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
