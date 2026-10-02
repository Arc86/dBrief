import CryptoKit
import Foundation

protocol NemotronEvaluationClock: Sendable {
    func now() -> Double
    func sleep(until seconds: Double) async throws
}

struct NemotronEvidenceRange: Codable, Sendable {
    let startSample: Int64
    let endSample: Int64
    init(_ range: Range<Int64>) { startSample = range.lowerBound; endSample = range.upperBound }
}

struct NemotronFixtureMetrics: Codable, Sendable {
    let fixtureID: String
    let language: String
    let status: String
    let sampleCount: Int64
    let readSampleCount: Int64
    let sha256: String
    let committedSamples: Int64
    let utterances: Int
    let textCharacters: Int
    let emissionTokens: Int
    let partialEvents: Int
    let maxHeldSamples: Int64
    let processingMs: [Double]
    let replacementMs: [Double]
    let maxPacingLagMs: Double
    let consumedBeforeFlushSamples: Int64
    let committedRanges: [NemotronEvidenceRange]
    let gaps: [NemotronEvidenceRange]
    let firstPartialFromUtteranceStartMs: [Double]
    let commitLagFromAcceptedEndMs: [Double]
    let finishAndReplacementMs: [Double]
    let failureStage: String?
}

struct NemotronEvaluationReport: Codable, Sendable {
    let schemaVersion: Int
    let status: String
    let qualityGate: String
    let timingProvenance: String
    var latencyScope: String = "fixture-inference-events; capture-UI-and-acoustic-latency-not-measured"
    let confidenceProvenance: String
    let runtime: String
    let osVersion: String
    let physicalMemoryBytes: UInt64
    let chunkMs: Int
    let lanes: Int
    let allowDownload: Bool
    let manifestSHA256: String
    let modelTreeSHA256: String?
    let modelPreparationMs: Double
    let fixtures: [NemotronFixtureMetrics]
}

struct NemotronEvaluationDriver: Sendable {
    let clock: any NemotronEvaluationClock
    let loadFactory: @Sendable (NemotronEvaluationOptions, [NemotronDecoderConfiguration.Language]) async throws -> any NemotronDecoderMaking
    func run(_ options: NemotronEvaluationOptions) async throws -> NemotronEvaluationReport {
        let manifestHandle = try FileHandle(forReadingFrom: options.manifest)
        defer { try? manifestHandle.close() }
        let manifestData = try manifestHandle.read(upToCount: 1_048_577) ?? Data()
        guard manifestData.count <= 1_048_576 else { throw NemotronSessionError.invalidConfiguration }
        let manifest = try JSONDecoder().decode(NemotronFixtureManifest.self, from: manifestData)
        try manifest.validate()
        guard manifest.fixtures.count >= options.lanes else { throw NemotronSessionError.invalidConfiguration }
        guard !FileManager.default.fileExists(atPath: options.report.path),
              FileManager.default.fileExists(atPath: options.report.deletingLastPathComponent().path) else {
            throw NemotronSessionError.invalidConfiguration
        }
        // Open/validate every path and boundary before any model download/load.
        let prepared = try manifest.fixtures.map { fixture in
            let input = try NemotronFixtureInput(fixture: fixture, directory: options.inputDirectory)
            let packets = try NemotronFixtureSchedule.packets(sampleCount: input.sampleCount,
                                                             utteranceEnds: fixture.utteranceEnds)
            return PreparedFixture(fixture: fixture, input: input, packets: packets)
        }
        let started = clock.now()
        let factory: any NemotronDecoderMaking
        do { factory = try await loadFactory(options, manifest.fixtures.map(\.language)) }
        catch {
            if error is CancellationError { throw error }
            return report(options, status: "failed", manifest: manifestData, modelHash: nil,
                          modelLoadMs: (clock.now() - started) * 1000, fixtures: [])
        }
        let loadMs = (clock.now() - started) * 1000
        var results: [NemotronFixtureMetrics] = []
        // At most two independent lanes share the same immutable factory.
        // No full-file PCM arrays or asynchronous packet backlog are created.
        for start in stride(from: 0, to: prepared.count, by: options.lanes) {
            try Task.checkCancellation()
            let batch = Array(prepared[start..<min(start + options.lanes, prepared.count)])
            let values = try await withThrowingTaskGroup(of: NemotronFixtureMetrics.self) { group in
                for fixture in batch {
                    group.addTask { try await self.runFixture(fixture, options: options, factory: factory) }
                }
                var values: [NemotronFixtureMetrics] = []
                for try await value in group { values.append(value) }
                return values
            }
            results += values
        }
        let order = Dictionary(uniqueKeysWithValues: manifest.fixtures.enumerated().map { ($0.element.id, $0.offset) })
        results.sort { order[$0.fixtureID]! < order[$1.fixtureID]! }
        return report(options, status: results.allSatisfy { $0.status == "completed" } ? "completed" : "failed",
            manifest: manifestData, modelHash: factory.modelFingerprint, modelLoadMs: loadMs, fixtures: results)
    }

    private struct PreparedFixture: Sendable {
        let fixture: NemotronFixtureManifest.Fixture
        let input: NemotronFixtureInput
        let packets: [NemotronFixturePacket]
    }

    private func runFixture(_ prepared: PreparedFixture, options: NemotronEvaluationOptions,
                            factory: any NemotronDecoderMaking) async throws -> NemotronFixtureMetrics {
        let metrics = FixtureMeasurement(clock: clock)
        let session = NemotronDecoderSession(factory: factory, emit: metrics.receive)
        let config = try NemotronDecoderConfiguration(language: prepared.fixture.language, chunkMs: options.chunkMs)
        var readSamples: Int64 = 0, processingMs: [Double] = [], finishMs: [Double] = [], maxLag: Double = 0
        var status = "completed", stage = "decoder-preparation"
        var failureStage: String?
        do {
            try await session.prepare(configuration: config)
            let start = clock.now()
            metrics.beginPacing(at: start)
            for (index, packet) in prepared.packets.enumerated() {
                try Task.checkCancellation()
                let deadline = start + Double(packet.range.upperBound) / 16000
                try await clock.sleep(until: deadline)
                stage = "pcm-read"
                let samples = try prepared.input.read(packet.range)
                readSamples = packet.range.upperBound
                let before = clock.now()
                stage = "decoder-process-accounting"
                try await session.append(samples: samples, startSample: packet.range.lowerBound)
                processingMs.append((clock.now() - before) * 1000)
                maxLag = max(maxLag, (clock.now() - deadline) * 1000)
                if packet.finishesUtterance {
                    stage = "finish-or-replacement"
                    let beforeFinish = clock.now()
                    try await session.finish(replacingDecoder: index + 1 < prepared.packets.count)
                    finishMs.append((clock.now() - beforeFinish) * 1000)
                }
            }
        } catch {
            if error is CancellationError { throw error }
            status = "failed"; failureStage = stage
        }
        return metrics.result(fixture: prepared.fixture, status: status, sampleCount: prepared.input.sampleCount,
            readSamples: readSamples, sha256: prepared.input.sha256,
            processingMs: processingMs, finishMs: finishMs, maxLag: maxLag, failureStage: failureStage)
    }

    private func report(_ options: NemotronEvaluationOptions, status: String, manifest: Data,
                        modelHash: String?, modelLoadMs: Double, fixtures: [NemotronFixtureMetrics]) -> NemotronEvaluationReport {
        .init(schemaVersion: 1, status: status, qualityGate: "not-evaluated", timingProvenance: "RNNT-emission-frames",
            confidenceProvenance: "synthetic-1.0-not-recognition-certainty", runtime: "FluidAudio-0.17.4",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, chunkMs: options.chunkMs, lanes: options.lanes,
            allowDownload: options.allowDownload,
            manifestSHA256: SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined(),
            modelTreeSHA256: modelHash, modelPreparationMs: modelLoadMs, fixtures: fixtures)
    }
}

struct NemotronMonotonicClock: NemotronEvaluationClock {
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now
    func now() -> Double {
        let value = origin.duration(to: clock.now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    func sleep(until seconds: Double) async throws {
        try await clock.sleep(until: origin.advanced(by: .seconds(seconds)))
    }
}

private final class FixtureMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: any NemotronEvaluationClock
    private var readyOrigin: Double
    private var replacements: [Double] = []
    private var committedSamples: Int64 = 0
    private var utterances = 0, characters = 0, tokens = 0, partials = 0
    private var held: Int64 = 0, consumed: Int64 = 0, currentConsumed: Int64 = 0, currentOrigin: Int64 = 0
    private var pacingOrigin: Double?
    private var firstPartial = false
    private var firstPartialMs: [Double] = [], commitLagMs: [Double] = []
    private var committedRanges: [NemotronEvidenceRange] = [], gaps: [NemotronEvidenceRange] = []
    init(clock: any NemotronEvaluationClock) { self.clock = clock; readyOrigin = clock.now() }
    func beginPacing(at time: Double) { lock.withLock { pacingOrigin = time } }
    func receive(_ event: NemotronDecoderEvent) {
        lock.withLock {
            switch event {
            case .ready(_, let origin):
                replacements.append((clock.now() - readyOrigin) * 1000)
                currentConsumed = 0; currentOrigin = origin; firstPartial = false
            case .partial(_, let text):
                partials += 1
                if !firstPartial, !text.isEmpty, let pacingOrigin {
                    firstPartialMs.append(max(0, (clock.now() - pacingOrigin - Double(currentOrigin) / 16000) * 1000))
                    firstPartial = true
                }
            case .progress(_, let value):
                held = max(held, value.heldSamples)
                consumed += value.consumedSamples - currentConsumed
                currentConsumed = value.consumedSamples
            case .committed(let value):
                committedSamples += Int64(value.range.count); utterances += 1
                characters += value.output.text.count; tokens += value.output.timings.count
                committedRanges.append(.init(value.range))
                if let pacingOrigin {
                    commitLagMs.append(max(0, (clock.now() - pacingOrigin - Double(value.range.upperBound) / 16000) * 1000))
                }
                readyOrigin = clock.now()
            case .gap(let range): gaps.append(.init(range))
            case .unavailable: break
            }
        }
    }
    func result(fixture: NemotronFixtureManifest.Fixture, status: String, sampleCount: Int64,
                readSamples: Int64, sha256: String, processingMs: [Double], finishMs: [Double], maxLag: Double,
                failureStage: String?) -> NemotronFixtureMetrics {
        lock.withLock {
            .init(fixtureID: fixture.id, language: fixture.language.rawValue, status: status,
                sampleCount: sampleCount, readSampleCount: readSamples, sha256: sha256,
                committedSamples: committedSamples, utterances: utterances, textCharacters: characters,
                emissionTokens: tokens, partialEvents: partials, maxHeldSamples: held,
                processingMs: processingMs, replacementMs: replacements, maxPacingLagMs: maxLag,
                consumedBeforeFlushSamples: consumed, committedRanges: committedRanges, gaps: gaps,
                firstPartialFromUtteranceStartMs: firstPartialMs, commitLagFromAcceptedEndMs: commitLagMs,
                finishAndReplacementMs: finishMs, failureStage: failureStage)
        }
    }
}
