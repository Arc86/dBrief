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

    /// `--eval-chat <transcript> --questions <q.json> [--mode full] [--fresh-session-per-question]`:
    /// asks each question against the full transcript and reports timings. Dev tooling only.
    static func runChat(arguments args: [String], output: FileHandle) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let path = value("--eval-chat"), let qPath = value("--questions") else { return 2 }
        guard (value("--mode") ?? "full") == "full" else { return 2 } // long: Task 10
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
