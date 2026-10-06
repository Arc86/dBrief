import Foundation
import Testing
import dBriefWire
@testable import dBrief

/// Needle-recall eval for Apple Intelligence analysis, driven by `scripts/gemma-eval.py
/// --engine apple`. Runs only when `DBRIEF_APPLE_EVAL=1` and `DBRIEF_EVAL_TRANSCRIPT`
/// point at a planted transcript; skipped in the normal suite.
@Suite struct AppleAnalysisEvalTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBRIEF_APPLE_EVAL"] == "1"))
    func analyzePlantedTranscript() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return }
        let path = try #require(ProcessInfo.processInfo.environment["DBRIEF_EVAL_TRANSCRIPT"])
        let text = try String(contentsOfFile: path, encoding: .utf8)
        EvalNotesDump.evalModeEnabled = true
        let start = ContinuousClock.now
        var report: [String: Any] = ["input_chars": text.count]
        // Map-reduce marker for the eval script: one stderr line per part state.
        let sink: MLProgress.Sink = { state in
            if case let .analyzingPart(index, total) = state {
                FileHandle.standardError.write(Data("analyzingPart(index: \(index), total: \(total))\n".utf8))
            }
        }
        do {
            let r = try await MLProgress.$sink.withValue(sink) {
                try await LocalAIService().analyzeTranscript(text, context: "", outputLanguage: .matchInput)
            }
            report["result"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r))
        } catch {
            report["error"] = error.localizedDescription
        }
        report["elapsed_s"] = (ContinuousClock.now - start).components.seconds
        print("APPLE_ANALYSIS " + String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self))
        #endif
    }
}
