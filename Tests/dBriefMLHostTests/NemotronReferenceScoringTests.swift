import Foundation
import Testing
@testable import dBriefMLHost

@Suite struct NemotronReferenceScoringTests {
    // Catch wrong normalization, edit selection, omitted deletions/insertions and
    // a misleading zero WER when there were no reference words.
    @Test func normalizesCasePunctuationAndCanonicalUnicodeWithoutRewritingNumbers() throws {
        #expect(try NemotronReferenceScorer.words("CAFÉ, cafe\u{301}! Project-42; 007.") == ["café", "café", "project", "42", "007"])
    }
    @Test func editCountsUseHandCheckedWordSequences() throws {
        let score = try NemotronReferenceScorer.score(reference: ["we", "ship", "on", "monday"],
            hypothesis: ["we", "launch", "on", "monday", "morning"])
        #expect(score == NemotronWordErrors(referenceWords: 4, hypothesisWords: 5, substitutions: 1, deletions: 0, insertions: 1))
        #expect(score.wordErrorRate == 0.5)
        let missing = try NemotronReferenceScorer.score(reference: ["alpha", "beta"], hypothesis: [])
        #expect(missing.deletions == 2)
        #expect(missing.wordErrorRate == 1)
        let empty = try NemotronReferenceScorer.score(reference: [], hypothesis: ["hallucinated"])
        #expect(empty.insertions == 1)
        #expect(empty.wordErrorRate == nil)
        #expect(try NemotronReferenceScorer.score(reference: ["same"], hypothesis: ["same"]).wordErrorRate == 0)
    }
    @Test func boundsScoringWorkBeforeAllocatingEditMatrix() {
        #expect(throws: (any Error).self) {
            try NemotronReferenceScorer.score(reference: Array(repeating: "word", count: 257), hypothesis: ["word"])
        }
        #expect(throws: (any Error).self) {
            try NemotronReferenceScorer.score(reference: ["word"], hypothesis: Array(repeating: "word", count: 513))
        }
    }
    @Test func acceptsExplicitAbsoluteReferencePath() throws {
        let args = ["--nemotron-evaluate", "--manifest", "/tmp/m.json", "--input-directory", "/tmp/in",
            "--model-directory", "/tmp/models", "--report", "/tmp/out.json", "--references", "/tmp/refs.json"]
        _ = try NemotronEvaluationOptions.parse(args)
        #expect(throws: (any Error).self) { try NemotronEvaluationOptions.parse(Array(args.dropLast()) + ["relative.json"]) }
    }
    @Test func referenceFileRequiresExactIDsAndBoundaryCoverage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = NemotronFixtureManifest(schemaVersion: 1, fixtures: [
            .init(id: "en-01", pcmFile: "en.f32le", language: .en, utteranceEnds: [1600, 3200])])
        let url = root.appendingPathComponent("refs.json")
        try Data(#"{"schemaVersion":1,"fixtures":[{"id":"en-01","utterances":[{"endSample":1600,"text":"hello"},{"endSample":3200,"text":"world"}]}]}"#.utf8).write(to: url)
        _ = try NemotronReferenceSet.load(at: url, manifest: manifest)
        for invalid in [
            #"{"schemaVersion":2,"fixtures":[]}"#,
            #"{"schemaVersion":1,"fixtures":[{"id":"other","utterances":[]}]}"#,
            #"{"schemaVersion":1,"fixtures":[{"id":"en-01","utterances":[{"endSample":3200,"text":"missing first"}]}]}"#,
            #"{"schemaVersion":1,"fixtures":[{"id":"en-01","utterances":[]},{"id":"en-01","utterances":[]}]}"#
        ] {
            try Data(invalid.utf8).write(to: url)
            #expect(throws: (any Error).self) { try NemotronReferenceSet.load(at: url, manifest: manifest) }
        }
        try Data(repeating: 32, count: 1_048_577).write(to: url)
        #expect(throws: (any Error).self) { try NemotronReferenceSet.load(at: url, manifest: manifest) }
        #expect(throws: (any Error).self) { try NemotronReferenceSet.load(at: root, manifest: manifest) }
    }

    @Test func missingRangesAndUnscorableHypothesesCannotProduceCompleteScores() {
        let references = [NemotronReferenceUtterance(range: 0..<10, words: ["first"]),
                          NemotronReferenceUtterance(range: 10..<20, words: ["second"])]
        var accumulator = NemotronReferenceAccumulator(references: references)
        accumulator.record(.init(generation: UUID(), range: 10..<20, output: .init(text: "second", timings: [])))
        let missing = accumulator.result(runCompleted: true)
        #expect(missing.status == "incomplete")
        #expect(missing.scoredUtterances == 1)
        #expect(missing.unscoredReferenceWords == 1)
        #expect(missing.wordErrorRate == nil)
        accumulator.record(.init(generation: UUID(), range: 0..<10,
            output: .init(text: String(repeating: "word ", count: 513), timings: [])))
        let oversized = accumulator.result(runCompleted: true)
        #expect(oversized.status == "incomplete")
        #expect(oversized.unscoredCommittedUtterances == 1)
        #expect(oversized.wordErrorRate == nil)
    }

    @Test func silenceReferencesExposeHallucinatedInsertionsWithoutInventingZeroWER() {
        var accumulator = NemotronReferenceAccumulator(references: [.init(range: 0..<10, words: [])])
        accumulator.record(.init(generation: UUID(), range: 0..<10, output: .init(text: "hallucinated", timings: [])))
        let score = accumulator.result(runCompleted: true)
        #expect(score.status == "complete")
        #expect(score.errors.insertions == 1)
        #expect(score.wordErrorRate == nil)
    }
}

private struct ReferenceTestClock: NemotronEvaluationClock {
    func now() -> Double { 0 }
    func sleep(until seconds: Double) async throws {}
}

private final class ScoringBarrierProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = 0
    private var scored = 0
    func nativeFinished() { lock.withLock { finished += 1 } }
    func score(_ value: NemotronReferenceAccumulator, _ complete: Bool) -> NemotronReferenceScore {
        lock.withLock {
            #expect(finished == 2, "Reference scoring overlapped unfinished native inference")
            scored += 1
        }
        return value.result(runCompleted: complete)
    }
    var scoredCount: Int { lock.withLock { scored } }
}

private actor BarrierDecoder: NemotronStreamingDecoder {
    let probe: ScoringBarrierProbe
    let slowerLane: Bool
    init(probe: ScoringBarrierProbe, slowerLane: Bool) { self.probe = probe; self.slowerLane = slowerLane }
    func process(samples: [Float]) async throws -> NemotronDecoderProgress {
        if slowerLane { try await Task.sleep(for: .milliseconds(200)) }
        return .init(consumedSamples: 0, heldSamples: Int64(samples.count))
    }
    func finish() async throws -> NemotronDecoderOutput {
        probe.nativeFinished()
        return .init(text: "hello", timings: [])
    }
}
private struct BarrierFactory: NemotronDecoderMaking {
    let probe: ScoringBarrierProbe
    func makeDecoder(configuration: NemotronDecoderConfiguration,
                     partial: @escaping @Sendable (String) -> Void) async throws -> any NemotronStreamingDecoder {
        BarrierDecoder(probe: probe, slowerLane: configuration.language == .nl)
    }
}

extension NemotronReferenceScoringTests {
    @Test func scoringWaitsForEveryNativeLaneInTheBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0,0,0,0]).write(to: root.appendingPathComponent("input.f32le"))
        try Data(#"{"schemaVersion":1,"fixtures":[{"id":"en-01","pcmFile":"input.f32le","language":"en","utteranceEnds":[1]},{"id":"nl-01","pcmFile":"input.f32le","language":"nl","utteranceEnds":[1]}]}"#.utf8)
            .write(to: root.appendingPathComponent("manifest.json"))
        try Data(#"{"schemaVersion":1,"fixtures":[{"id":"en-01","utterances":[{"endSample":1,"text":"hello"}]},{"id":"nl-01","utterances":[{"endSample":1,"text":"hello"}]}]}"#.utf8)
            .write(to: root.appendingPathComponent("references.json"))
        let options = try NemotronEvaluationOptions.parse(["--nemotron-evaluate", "--manifest", root.appendingPathComponent("manifest.json").path,
            "--input-directory", root.path, "--model-directory", root.path,
            "--report", root.appendingPathComponent("report.json").path, "--lanes", "2",
            "--references", root.appendingPathComponent("references.json").path])
        let probe = ScoringBarrierProbe()
        let driver = NemotronEvaluationDriver(clock: ReferenceTestClock(), loadFactory: { _, _ in BarrierFactory(probe: probe) },
                                             scoreReferences: probe.score)
        let report = try await driver.run(options)
        #expect(report.status == "completed")
        #expect(probe.scoredCount == 2)
    }

    // Catch scoring partials, shifting a missing utterance onto the wrong
    // reference, hiding interrupted coverage, or serializing private words.
    @Test(arguments: [false, true]) func runnerScoresCommittedRangesAndQualifiesInterruptedCoverage(failReplacement: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var pcm = Data()
        for value: Float in [7, 8, 9] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { pcm.append(contentsOf: $0) }
        }
        try pcm.write(to: root.appendingPathComponent("input.f32le"))
        try Data(#"{"schemaVersion":1,"fixtures":[{"id":"en-01","pcmFile":"input.f32le","language":"en","utteranceEnds":[2,3]}]}"#.utf8)
            .write(to: root.appendingPathComponent("manifest.json"))
        try Data(#"{"schemaVersion":1,"fixtures":[{"id":"en-01","utterances":[{"endSample":2,"text":"7 confidential"},{"endSample":3,"text":"9 private"}]}]}"#.utf8)
            .write(to: root.appendingPathComponent("references.json"))
        let args = ["--nemotron-evaluate", "--manifest", root.appendingPathComponent("manifest.json").path,
            "--input-directory", root.path, "--model-directory", root.path,
            "--report", root.appendingPathComponent("report.json").path,
            "--references", root.appendingPathComponent("references.json").path]
        let options = try NemotronEvaluationOptions.parse(args)
        let driver = NemotronEvaluationDriver(clock: ReferenceTestClock(), loadFactory: { _, _ in
            FixtureFactory(failAt: failReplacement ? 2 : nil)
        })
        let report = try await driver.run(options)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!json.contains("confidential"))
        #expect(!json.contains("private"))
        #expect(!json.contains("7 8"))
        #expect(!json.contains(root.path))
        #expect(report.qualityGate == "not-evaluated")
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect((object["referenceSHA256"] as? String)?.count == 64)
        let fixture = try #require((object["fixtures"] as? [[String: Any]])?.first)
        let score = try #require(fixture["referenceScore"] as? [String: Any])
        #expect(score["expectedUtterances"] as? Int == 2)
        #expect(score["plannedReferenceWords"] as? Int == 4)
        #expect(score["scoredUtterances"] as? Int == (failReplacement ? 1 : 2))
        #expect(score["status"] as? String == (failReplacement ? "incomplete" : "complete"))
        let errors = try #require(score["errors"] as? [String: Int])
        #expect(errors["referenceWords"] == (failReplacement ? 2 : 4))
        #expect(errors["hypothesisWords"] == (failReplacement ? 2 : 3))
        #expect(errors["substitutions"] == 1)
        #expect(errors["deletions"] == (failReplacement ? 0 : 1))
        #expect(errors["insertions"] == 0)
        if failReplacement { #expect(score["wordErrorRate"] == nil) }
        else { #expect(score["wordErrorRate"] as? Double == 0.5) }
    }

    @Test func invalidReferencesFailBeforeNativeFactorySideEffects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0,0,0,0]).write(to: root.appendingPathComponent("input.f32le"))
        try Data(#"{"schemaVersion":1,"fixtures":[{"id":"en-01","pcmFile":"input.f32le","language":"en","utteranceEnds":[1]}]}"#.utf8)
            .write(to: root.appendingPathComponent("manifest.json"))
        try Data(#"{"schemaVersion":1,"fixtures":[]}"#.utf8).write(to: root.appendingPathComponent("references.json"))
        let options = try NemotronEvaluationOptions.parse(["--nemotron-evaluate", "--manifest", root.appendingPathComponent("manifest.json").path,
            "--input-directory", root.path, "--model-directory", root.path,
            "--report", root.appendingPathComponent("report.json").path,
            "--references", root.appendingPathComponent("references.json").path])
        let driver = NemotronEvaluationDriver(clock: ReferenceTestClock(), loadFactory: { _, _ in
            Issue.record("Invalid references reached native model preparation")
            return FixtureFactory()
        })
        await #expect(throws: NemotronSessionError.invalidConfiguration) { try await driver.run(options) }
    }
}
