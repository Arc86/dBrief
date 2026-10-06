import Foundation
import dBriefWire

/// `--eval-insights <file>`: one Gemma analysis outside the request loop, for
/// measuring long-context behavior (see scripts/gemma-eval.py). Dev tooling only.
enum GemmaEval {
    static func run(arguments args: [String]) async -> Int32 {
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
            let result = try await service.analyzeTranscript(text, outputLanguage: language)
            let elapsed = ContinuousClock.now - start
            let resultJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
            let report: [String: Any] = [
                "elapsed_s": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                "peak_memory_mb": MLXInsightsService.peakMemoryBytes() / 1_048_576,
                "input_chars": text.count,
                "result": resultJSON,
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            return 0
        } catch {
            let data = (try? JSONSerialization.data(withJSONObject: ["error": "\(error)"])) ?? Data()
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            return 1
        }
    }
}
