import Foundation
import Testing
@testable import dBriefMLHost

@Suite struct NemotronEvaluationRunnerTests {
    private let options = ["--nemotron-evaluate", "--manifest", "/tmp/manifest.json", "--input-directory", "/tmp/fixtures",
                           "--model-directory", "/tmp/models", "--report", "/tmp/report.json"]
    @Test func downloadsRequireSeparateExplicitOptIn() throws {
        #expect(try !NemotronEvaluationOptions.parse(options).allowDownload)
        #expect(try NemotronEvaluationOptions.parse(options + ["--allow-download"]).allowDownload)
    }
    @Test func rejectsMissingDuplicateUnknownAndRelativePathArguments() {
        for arguments in [Array(options.dropLast(2)), options + ["--report", "/tmp/other.json"],
                          options + ["--unknown"], options + ["--lanes", "3"], options + ["--chunk-ms", "0"],
                          ["--nemotron-evaluate", "--manifest", "relative.json", "--input-directory", "/tmp/f",
                           "--model-directory", "/tmp/m", "--report", "/tmp/r"]] {
            #expect(throws: (any Error).self) { try NemotronEvaluationOptions.parse(arguments) }
        }
    }
    @Test func packetScheduleSplitsAtBoundariesAndIncludesShortTail() throws {
        let packets = try NemotronFixtureSchedule.packets(sampleCount: 4100, utteranceEnds: [1700, 4100])
        #expect(packets.map(\.range) == [0..<1600, 1600..<1700, 1700..<3300, 3300..<4100])
        #expect(packets.map(\.finishesUtterance) == [false, true, false, true])
    }
    @Test func invalidOrUnboundedUtterancesCannotEnterSchedule() {
        for ends: [Int64] in [[0, 4100], [2000, 1700, 4100], [4000], [4101], [4100, 4100]] {
            #expect(throws: (any Error).self) { try NemotronFixtureSchedule.packets(sampleCount: 4100, utteranceEnds: ends) }
        }
        #expect(throws: (any Error).self) { try NemotronFixtureSchedule.packets(sampleCount: 240001, utteranceEnds: [240001]) }
    }
    @Test func rejectsDuplicateFixtureIDsAndUnsupportedSchema() throws {
        let f = NemotronFixtureManifest.Fixture(id: "en-01", pcmFile: "en.f32le", language: .en, utteranceEnds: [1600])
        #expect(throws: (any Error).self) { try NemotronFixtureManifest(schemaVersion: 1, fixtures: [f, f]).validate() }
        #expect(throws: (any Error).self) { try NemotronFixtureManifest(schemaVersion: 2, fixtures: [f]).validate() }
        try NemotronFixtureManifest(schemaVersion: 1, fixtures: [f]).validate()
    }
}

extension NemotronEvaluationRunnerTests {
    @Test func normalizedInputRejectsEscapesSymlinksAndMalformedPCM() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 0, 0, 0, 0, 0, 0x80, 0x3f]).write(to: root.appendingPathComponent("valid.f32le"))
        let f = NemotronFixtureManifest.Fixture(id: "safe", pcmFile: "valid.f32le", language: .en, utteranceEnds: [2])
        let input = try NemotronFixtureInput(fixture: f, directory: root)
        #expect(input.sampleCount == 2)
        #expect(try input.read(0..<2) == [0, 1])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.f32le"), withDestinationURL: root.deletingLastPathComponent())
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("bad.f32le"))
        for name in ["../outside.f32le", "escape.f32le", "bad.f32le"] {
            let bad = NemotronFixtureManifest.Fixture(id: "bad", pcmFile: name, language: .auto, utteranceEnds: [2])
            #expect(throws: (any Error).self) { try NemotronFixtureInput(fixture: bad, directory: root) }
        }
    }
    @Test func fullBundleAndTierMustMatchBeforeModelLoading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try NemotronDecoderConfiguration(language: .nl)
        for metadata in [
            #"{"sample_rate":16000,"chunk_ms":1120,"chunk_mel_frames":112,"vocab_size":13087,"prompt_dictionary":{"auto":101,"en":10,"nl":11}}"#,
            #"{"sample_rate":16000,"chunk_ms":2240,"chunk_mel_frames":224,"vocab_size":13087,"prompt_dictionary":{"auto":101,"en":10,"nl":11}}"#,
            #"{"sample_rate":16000,"chunk_ms":1120,"chunk_mel_frames":112,"vocab_size":2829,"prompt_dictionary":{"auto":101,"en":10,"nl":11}}"#,
            #"{"sample_rate":16000,"chunk_ms":1120,"chunk_mel_frames":112,"vocab_size":13087,"prompt_dictionary":{"auto":101,"en":10}}"#
        ].enumerated() {
            try Data(metadata.element.utf8).write(to: root.appendingPathComponent("metadata.json"))
            if metadata.offset == 0 { try NemotronDecoderFactory.validateMetadata(at: root, configuration: configuration) }
            else { #expect(throws: (any Error).self) { try NemotronDecoderFactory.validateMetadata(at: root, configuration: configuration) } }
        }
    }
}

extension NemotronEvaluationRunnerTests {
    @Test func publishedMetadataDerivesTierFromMelFramesWhenChunkMsIsAbsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"sample_rate":16000,"chunk_mel_frames":112,"vocab_size":13087,"prompt_dictionary":{"auto":101,"en":0,"nl":16}}"#.utf8).write(to: root.appendingPathComponent("metadata.json"))
        try NemotronDecoderFactory.validateMetadata(at: root, configuration: .init(language: .nl))
    }
}

private final class ImmediateEvaluationClock: NemotronEvaluationClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 0
    private var sleeps: [Double] = []
    func now() -> Double { lock.withLock { time } }
    func sleep(until seconds: Double) async throws { lock.withLock { sleeps.append(seconds); time = max(time, seconds) } }
    var deadlines: [Double] { lock.withLock { sleeps } }
}

extension NemotronEvaluationRunnerTests {
    @Test func pacedDriverReportsCountsWithoutTranscriptContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var pcm = Data()
        for value: Float in [7, 8, 9] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { pcm.append(contentsOf: $0) }
        }
        try pcm.write(to: root.appendingPathComponent("fixture.f32le"))
        try Data(#"{"schemaVersion":1,"fixtures":[{"id":"private-01","pcmFile":"fixture.f32le","language":"nl","utteranceEnds":[2,3]}]}"#.utf8).write(to: root.appendingPathComponent("manifest.json"))
        let opts = try NemotronEvaluationOptions.parse(["--nemotron-evaluate", "--manifest", root.appendingPathComponent("manifest.json").path,
            "--input-directory", root.path, "--model-directory", root.appendingPathComponent("models").path,
            "--report", root.appendingPathComponent("report.json").path])
        let clock = ImmediateEvaluationClock()
        let driver = NemotronEvaluationDriver(clock: clock, loadFactory: { _, _ in FixtureFactory() })
        let report = try await driver.run(opts)
        let metrics = try #require(report.fixtures.first)
        #expect(report.status == "completed")
        #expect(report.qualityGate == "not-evaluated")
        #expect(metrics.committedSamples == 3)
        #expect(metrics.utterances == 2)
        #expect(metrics.textCharacters == 4)
        #expect(clock.deadlines == [2.0 / 16000, 3.0 / 16000])
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!json.contains("7 8"))
        #expect(!json.contains(root.path))
        #expect(metrics.sha256.count == 64)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let rows = try #require(object["fixtures"] as? [[String: Any]])
        #expect(rows[0]["consumedBeforeFlushSamples"] as? Int == 0)
        #expect(rows[0]["committedRanges"] as? [[String: Int]] == [
            ["startSample": 0, "endSample": 2], ["startSample": 2, "endSample": 3]])
        let delays = try #require(rows[0]["firstPartialFromUtteranceStartMs"] as? [Double])
        #expect(delays.count == 2)
        #expect(abs(delays[0] - 0.125) < 1e-9)
        #expect(abs(delays[1] - 0.0625) < 1e-9)
    }

    @Test func failedDecoderRunCannotBeReportedAsCompleted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0,0,0,0]).write(to: root.appendingPathComponent("input.f32le"))
        try Data(#"{"schemaVersion":1,"fixtures":[{"id":"failure-01","pcmFile":"input.f32le","language":"auto","utteranceEnds":[1]}]}"#.utf8).write(to: root.appendingPathComponent("manifest.json"))
        let opts = try NemotronEvaluationOptions.parse(["--nemotron-evaluate", "--manifest", root.appendingPathComponent("manifest.json").path,
            "--input-directory", root.path, "--model-directory", root.path, "--report", root.appendingPathComponent("report.json").path])
        let driver = NemotronEvaluationDriver(clock: ImmediateEvaluationClock(), loadFactory: { _, _ in FixtureFactory(failFinish: true) })
        let report = try await driver.run(opts)
        #expect(report.status == "failed")
        #expect(report.fixtures.first?.committedSamples == 0)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let rows = try #require(object["fixtures"] as? [[String: Any]])
        #expect(rows[0]["gaps"] as? [[String: Int]] == [["startSample": 0, "endSample": 1]])
        let two = NemotronEvaluationOptions(manifest: opts.manifest, inputDirectory: opts.inputDirectory,
            modelDirectory: opts.modelDirectory, report: opts.report, chunkMs: opts.chunkMs, lanes: 2, allowDownload: false)
        await #expect(throws: NemotronSessionError.invalidConfiguration) { try await driver.run(two) }
    }
}

extension NemotronEvaluationRunnerTests {
    @Test func reportPublicationIsPrivateAndCannotReplaceAnExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = NemotronEvaluationReport(schemaVersion: 1, status: "failed", qualityGate: "not-evaluated",
            timingProvenance: "RNNT-emission-frames", confidenceProvenance: "synthetic", runtime: "test",
            osVersion: "test", physicalMemoryBytes: 0, chunkMs: 1120, lanes: 1, allowDownload: false,
            manifestSHA256: "test", modelTreeSHA256: nil, modelPreparationMs: 0, fixtures: [])
        let url = root.appendingPathComponent("report.json")
        try NemotronEvaluationRunner.write(report, to: url)
        let decoded = try JSONDecoder().decode(NemotronEvaluationReport.self, from: Data(contentsOf: url))
        #expect(decoded.status == "failed")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let saved = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try NemotronEvaluationRunner.write(report, to: url) }
        #expect(try Data(contentsOf: url) == saved)
    }

    @Test func evaluationHelpDoesNotRequireProductionSupportPath() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = Process(), stdout = Pipe(), stderr = Pipe()
        helper.executableURL = repo.appendingPathComponent(".build/debug/dBriefMLHost")
        helper.arguments = ["--nemotron-evaluate", "--help"]
        helper.standardInput = FileHandle.nullDevice; helper.standardOutput = stdout; helper.standardError = stderr
        try helper.run(); helper.waitUntilExit()
        let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(helper.terminationStatus == 0)
        #expect(text.contains("--input-directory"))
        #expect(text.contains("--allow-download"))
    }
}
